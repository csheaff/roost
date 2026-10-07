# Validation

## After 0.7.0 — 2026-10-04

- **GitHub issues.** The host's `issues` action listed tmux-control's real open
  issue (#70) through `gh`. In a test Emacs with the author's configuration,
  `C-c C-t` in a draft offered it; choosing it filled the prompt from the issue
  and named the task `70-off-by-one-scroll-cursor-relative`.
- **Org to merge, with an agent.** In a throwaway repository, a draft opened on
  an Org heading took the heading and its notes as the prompt; creating the
  task recorded `ROOST_TASK` on the heading. Claude Code (Haiku 4.5) stopped at
  folder trust (the mode line showed `Roost:1`), then asked to edit and to
  commit. The ready notification read "Done. The greet() function now returns
  "Hello, Alice!"…". Run on the heading, `roost-merge-retire` merged the
  commit and retired the task.
- **The command menu.** `h` in the dashboard opened `roost-dispatch` only after
  an alias left from 0.2, which redefined the name as `roost-new-task`, was
  removed; a test now guards it.
- **Shared SSH connections.** Against `claylien` on a LAN, a bare `ssh true`
  took 0.34 s alone and 0.13 s over a shared connection. Through Roost, the
  request that started the shared connection returned in 0.72 s and the next in
  0.39 s, with no hang from the backgrounded master. ssh refuses control socket
  paths of 104 bytes or more, so long state directories don't share.
- **MELPA.** `package-build` built both packages from GitHub, with Roost's
  helper in `scripts/`; see [MELPA](melpa.md).

**88 ERT tests and 66 Python tests pass**; byte compilation has no warnings.

## Developing Roost with Roost — 2026-10-04

The pull request flow, follow-up prompts and the agent's latest reply were
built by Roost tasks working on Roost, then used for real on
[csheaff/roost](https://github.com/csheaff/roost):

- **#1 (local).** `P` drafted the pull request from the agent's commit message
  and created it with `gh`. Copilot's review and other review notes went to the agent
  with `e`; `P` pushed each fix ("Pushed 1 commit to #1"). After a squash merge
  on GitHub, `x` retired the task and deleted its local and remote branches.
- **#2 (from `claylien`).** The first `P` failed at the push: the host's
  global Git config rewrites GitHub URLs to SSH, and it has no GitHub SSH key.
  That task's own change made the failure fast and explained, and the
  `roost-doctor` push check now reports it up front. With a repo-local URL
  override the pull request was created from the remote host; three Copilot
  rounds (askpass helpers, test isolation, a controlling terminal) went to the
  agent the same way, and the last (orphaned helpers on timeout) was fixed on
  `main`. `x` on `claylien` retired it and deleted the GitHub branch.

Using it found and fixed: changes measured from a task's starting commit
counted the integration branch's commits after `u`; `n` skipped a blocked task
you had just created; pull request drafts used the agent's prompt as the body;
multi-line errors in draft header lines; a merged pull request that looked like
unfinished work; a long prompt pushing the reply off the task panel.

**79 ERT tests and 65 Python tests pass**; `roost.el` byte-compiles without
warnings.

## Fresh install — 2026-10-04

A new Emacs 30.2 configuration (`--init-directory`, nothing from the author's
setup) installed Roost the way the README describes: tmux-control and Roost
from GitHub with `use-package :vc`, Eat from NonGNU ELPA, and Evil from MELPA,
with `tab-bar-mode` on and Roost pointed at an isolated state directory.

- Roost loaded from the package directory and found its helper.
- `roost-doctor` reported versions locally and on `claylien`, flagged the
  Mac's Codex 0.150.1 as too old for Codex tasks, and for an unknown host
  showed the SSH error with a fix.
- With Evil, the dashboard opened in Emacs state with its empty-state help, `c`
  opened a draft in insert state, a project chosen over plain `/ssh:` TRAMP
  created a task, and Roost opened it in its own tab.
- Two problems were in tmux-control and are fixed in
  [tmux-control#150](https://github.com/csheaff/tmux-control/pull/150): agent
  terminals opened in Evil normal state, so answering a permission prompt
  started a numeric prefix instead of reaching the agent; and `package-vc`
  compiled its `test/` files, printing load errors during install.
- `package-lint` reports only that tmux-control is not yet on an archive.

## Review and dogfooding pass — 2026-10-04

### Automated checks

- **48 ERT tests and 41 Python lifecycle tests pass** on macOS; `roost.el`
  byte-compiles without warnings. The Python tests also pass on `claylien`
  (Ubuntu, Python 3.13.7, tmux 3.7c) in a temporary directory and socket.
- New coverage: unretirable records (failed spawn, detached primary checkout,
  worktree and branch removed by hand) and `forget`; live panes restoring a
  `crashed` task and blocking retirement; unreadable tmux versus no server;
  opening a dead pane; Git statistics running outside the registry lock;
  branch prefixes; null and legacy `{}` request values; setup rerun after a
  failed first run; inherited PATH order; legacy retired records; updating from
  the integration branch with and without conflicts; conflict messages; the
  stable Codex hook command; a confirmed send after a permission prompt.
- Emacs-side coverage: JSON null encoding and repair of hosts files written as
  `{}`; queued manual refresh and backoff; the grouped dashboard (summary,
  ordering, point preservation, narrow windows, empty state); the task picker;
  the task panel; the new task draft (defaults, forks, derived names,
  read-only fields, failed creation keeping the draft).

### Live use

A separate GUI Emacs with the author's configuration used an isolated state
directory and tmux socket (`roost-qa`), so the existing user task and socket
were untouched. Two disposable projects were used: `ledger` on `claylien` and
`notes` on the Mac. Claude Code 2.1.289 ran Haiku 4.5; Codex 0.160.0 ran
`gpt-6-luna`.

1. Created tasks through the old prompts, then through the new draft buffer,
   locally and over TRAMP. Claude and Codex trust prompts appear once per
   repository: both record trust for the primary checkout.
2. Watched permission requests, `ready` and `running` in the dashboard and
   notifications; cycled with `n`; answered prompts in the native terminals.
3. Restarted Emacs entirely. Reopening the dashboard found all three running
   tasks on both hosts and reconnected to a pending permission prompt.
4. Ran tests independently in the task shell, reviewed and committed in Magit
   over TRAMP and locally, and merged with `m`.
5. Two tasks edited the same files. Merging the second reported the conflicting
   files and changed nothing. `u` merged `main` into the task's worktree, and
   the agent resolved the conflicts, ran the tests and committed when asked
   (Claude and Codex). Both merges then succeeded. The demo's `main` ended with
   CSV import fixes, Decimal totals and JSON output from three agents.
6. Declining a Claude permission emits no hook; the task stayed `permission`
   for over two minutes while Claude waited. A confirmed `e` delivered the next
   prompt and the task returned to `ready`.

Findings that changed the code are described in the commit history: a
five-prompt creation flow, a dashboard that repeated columns and colored
permission like ready, a task panel without the prompt or changes, `n` not
favoring blocked agents, the stale permission dead end, conflicts without a
next step, and Codex re-reviewing hooks after every upgrade.

One attempted fix was reverted: passing the shared `.git` to Codex with
`--add-dir` did not let it commit, because its sandbox keeps `.git`
directories read-only. Codex asks before committing in a worktree.

## Earlier validation — 2026-10-03

The record below predates the 0.5 changes; commands such as `SPC r c` refer to
the author's bindings and the old minibuffer creation prompts.

### Automated checks

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

### Actual Claude and native Emacs

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

### Developer workflow after the Orca comparison

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

### Compact perspective bar and README captures

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

### Sidebar and task panel

On 2026-10-04, exercised both in a separate GUI Emacs 30.2 running the user's
perspective.el, Xah, tmux-control and Magit configuration, with its own task
registry and tmux socket. The tasks ran the fake Claude lifecycle fixture
through the real hooks, so no agent credits were used.

- Loading Roost adds no hooks; melpazoid reports nothing. The dashboard opens
  on its own, and `b` adds the sidebar to every frame at least 110 columns
  wide. A new 60-column frame was left alone; a new 160-column one got the
  sidebar.
- On a 150-column frame, opening a task left its terminal all 120 columns.
  Widening the frame to 200 docked the panel beside it, which fetched the
  task's Git changes rather than staying at "Refreshing…".
- With two task perspectives, the panel followed manual `persp-switch`es
  between them, and the main perspective had none. After the sidebar was
  turned off, switching to a perspective saved with it removed it.
- A panel scrolled to its Actions kept its place across buffer switches in the
  main window and background redraws. It used to jump back to the top.
- `q` in the panel turned the panel off for every task, returning to the
  terminal; `I` in the sidebar turned it back on and left the sidebar selected.
  `q` in the sidebar hid it and selected the main window.
- The README capture, in a plain Emacs with two Claude Code (Haiku) tasks in a
  local project, showed the docked panel cutting its prompt off at the window
  edge: Emacs truncates lines in windows narrower than 50 columns. The panel
  now wraps them, without fringe arrows.
- The same two tasks were then taken through to the end from the sidebar:
  permission prompts answered in the terminal, `r` for Magit, a commit there,
  `m` to merge the first task, `u` on the second, which conflicted with it in
  `notes.py` and which its agent resolved when Roost offered, and `m` again.
  Both merges landed in `main`, whose tests pass and whose `list --tag` and
  `export` commands work. Doing this found and fixed:
  - Changes and commits went stale while agents worked: background polls
    skip Git statistics, so an agent that edited files still showed "No
    changes yet". A poll that sees an agent report anything now measures that
    task (without asking GitHub), and Magit refreshing a task's worktree does
    too, so a commit made there shows up.
  - After a merge, the other tasks still showed 0 behind until a manual
    refresh; merging now measures every task on the host.
  - `r` from the sidebar opened Magit in the task panel's window: Emacs clears
    a side window's dedication when it shows another buffer, which happens
    when the panel switches tasks.
  - Two tasks with the same name on one host shared a panel buffer.
  - Without workspaces, the panel followed only `RET`, not `r` or other task
    commands.
  - Both tasks still counted as waiting after their replies had been read, so
    the mode line kept saying `Roost:2`. A ready agent you have opened, or
    whose terminal you are watching while Emacs has focus, now counts as seen
    until its next event. Checked live with the fake agent: unfocused, it kept
    counting; focused on its terminal, the count cleared.
- The panel lists a task's changed files: in a worktree with one edited,
  one new and one deeply nested new file, it showed `+2 −0`, `new` and
  `new` against paths cut to keep their file names, and clicking the edited
  one opened its Magit diff in the main area.
- An earlier pass with a long reply seeded in the cache checked the folded
  six-line preview, clicking to expand and collapse it, a new reply starting
  folded, and the sidebar's hover text giving the full name, host and project.

All **114 ERT tests and 69 Python tests** pass, with byte compilation under
warnings-as-errors. Batch Emacs has no redisplay, so the tests call the layout
sync directly where the window hook would run it.

### A day of testing, 2026-10-05

Before recapturing the README images, Roost and tmux-control were tested
broadly: the fake agent through the real hooks for most scenarios, Claude Code
(Haiku) where a real reply mattered, on this Mac and on `claylien`.

- **Static and install.** package-lint, melpazoid and checkdoc as before; a
  fresh `package-vc-install` of both packages from GitHub into an empty
  Emacs loads, finds the host helper and passes `roost-doctor`'s local
  checks. `roost-doctor` passes on both hosts.
- **Lifecycle, in Clay's configuration** (perspective.el, xah-fly-keys, his
  mode line), in a copy of it with its own state and tmux socket: a draft
  submitted with keys, `e`, a permission request found by `n`, `K` and `s`,
  `t` with the tiled shell, scrollback, a window renamed from outside tmux,
  `m` from the sidebar with the other task's behind count updating, `u` into a
  conflict, `X` and `x`; on `claylien`, the same through to a merge, with
  changed files appearing as the agent worked. Two frames each kept their own
  task's panel.
- **Plain Emacs, terminal Emacs and tmux-control alone.** Sessions with the
  same name on two sockets, a session named like another's scrollback,
  bookmarks, diagnostics and the all-sessions grid; Roost in `emacs -nw`;
  task names with accents and wide characters; Ediff beside the side
  windows; the long-reply preview with a real reply.
- **Suites.** 119 ERT and 71 Python tests, the Python ones also on
  `claylien` (Python 3.13, tmux 3.7c); tmux-control's 308 ERT tests and 32
  live integration scenarios.

Found and fixed: `X` asked to forget a running agent's task and only then
said to stop it first (it now offers to do both); unloading Roost left task
panels in other frames; the list of changed files could be saved into task
records; long paths in wide scripts raised an error; sidebar lines lost their
last character in a terminal; measuring the panel's width moved point while
it was drawn, scrambling it (introduced and caught the same day); and
`git status` behind the statistics could take the index lock while an agent
committed. Notifications also no longer fire for the agent you are watching.

The largest find came while capturing the README images: tmux was not
resized when a terminal's window changed size. Emacs reports a new size only
to the process of the buffer in the window, and Roost's terminals are
tmux-control's per-window buffers, which have none; an agent kept drawing at
84x6 in a 128x26 window after `C-x 1`. tmux-control now follows those windows
([tmux-control#158](https://github.com/csheaff/tmux-control/pull/158)). Roost
also docked its panel from inside Emacs's window change hook, where a resize
goes unreported to every package; it now changes side windows just after
redisplay. Splits, `C-x 1`, the panel turning on and off and four frame sizes
then each left tmux at exactly the terminal window's size.

Recapturing the dashboard found one more. A commit made in a task's shell
rather than by its agent left the dashboard saying `uncommitted` until `g`,
since background polls measure only tasks whose agents have reported
something. Each poll now stamps every task with the modification times of
its worktree's index and `HEAD` reflog and its integration branch's reflog,
read with `stat` and no Git process, and Emacs measures a task whose stamp
moved. Saving a file in a worktree, which leaves the index alone, measures its
task too. Live, a commit from a shell showed up four seconds later, and a save
with polling paused updated the count at once.

Then, with Claude Code 2.1.289 (Haiku) and a probe session logging every hook
event:

- **Turns you stop.** Declining a permission request, or pressing Esc while
  the agent works, runs no hook at all (no `Stop`, `PostToolUseFailure` or
  `PermissionDenied`, and no `idle_prompt` notification in the two minutes
  after), so Roost kept showing `permission` or `running` until the next
  prompt. Claude's transcript records the interrupt (`[Request interrupted by
  user]`); a listing now reads the end of a working Claude task's transcript
  and marks it `ready` when that marker is newer than its last hook. Live, a
  declined request and an Esc during a command each showed `ready` within
  four seconds. An Esc before the first word of a reply leaves no marker
  (Claude puts the prompt back in the input box), and an approval writes
  nothing until the command finishes, so both still go unseen.
- **What a request asks.** The dashboard, the task panel and notifications
  said only `permission`, with the agent's last words. The hook's tool and
  input now give `Asks to run date -u > /tmp/…` or `Asks to edit notes.py`,
  kept through the notification that follows a request and cleared when the
  agent moves on. A multiple-choice question from the agent arrives the same
  way (its `AskUserQuestion` tool asks permission first), and reads `Asks:
  Which color do you prefer?`; a plan waiting for approval, `Asks you to
  approve its plan`.
- **New files.** An agent that only added files showed `uncommitted` with no
  count, since `git diff --shortstat` leaves out untracked files. The
  dashboard counts them from the list of changed files: `1 new file`, or
  `2 files +10 −3 · 1 new`.

Helpers no longer pile up: each host kept a copy of every helper version
Emacs had installed (eight in the capture state after a day of edits). A
task now records the helper that launched it, whose copy its hooks call,
and launching a task deletes copies that no task records and no Emacs has
installed in a week. Hosts with tasks from before the record keep every copy
until those tasks end.

All 123 ERT and 77 Python tests pass.

### The first hour in a real configuration, 2026-10-05

Then the question became what would make someone give up in their first hour.
Roost ran in a copy of Clay's configuration (xah-fly-keys, perspective.el, his
mode line, his window keys), first with a raw key echo and the fake agent,
then with Claude Code (Haiku):

- **Keys.** Esc never reached the agent: the configuration sends it to xah
  command mode, so it neither interrupted Claude nor cancelled its prompts.
  In tmux terminals it now goes to the program and C-SPC leaves insert mode
  (a configuration change). Entering a Roost window in command mode, by
  C-h/C-l or a click, ran the sidebar's keys as xah commands; insert mode now
  follows window selection too. Shift+Return submitted half-written prompts:
  tmux-control now sends it, and Option+Return, as tmux's named keys
  ([tmux-control#160](https://github.com/csheaff/tmux-control/pull/160),
  #162; tmux 3.2a–3.4 type the name S-Enter out, so only 3.5 and later),
  and Roost turns on tmux's `extended-keys` before starting an agent, without
  which tmux gives Claude Return anyway. With extended keys Claude ignores
  ESC Return, hence #162. Cmd-V, C-y, C-c C-c, Shift+Tab, C-o, C-r, arrows
  and word keys arrive intact.
- **Windows.** The task draft and the dashboard popped up beside the
  selected window and squeezed an agent's terminal to 19 columns; they now
  take the window you are in. `n`, `c`, `b` and `S` now work in a task's
  panel. Magit, help, `C-x 1`, Ediff, window moves and killing a terminal
  buffer leave agents and side windows alone.
- **Speed.** Idle with a tmux view open, Emacs redisplayed 24 times a second:
  tmux-control's optional idle GC polled every 50 ms. It now uses idle timers
  ([tmux-control#161](https://github.com/csheaff/tmux-control/pull/161)),
  about a sixth of the CPU. Typing echoes in 3 ms locally and 12 ms on
  claylien; three agents streaming in the background cost nothing visible;
  one streaming on screen, about 16% of a core.
- **Smaller things.** A sleeping host's error printed again whenever ssh
  reworded it; the C-c that a cooked-mode agent gets as SIGINT killed the
  runner too; `m` on uncommitted work asked to merge, then refused (it now
  offers Magit); "command's" named a task `command-s`; Claude's no-break
  spaces showed as red underscores (#163).
- **Not ours.** Claude Code leaves `3. Nohift+tab)` in its edit prompt at
  some widths, in plain tmux with any `TERM` too. Its folder-trust question
  defaults to "No, exit"; it asks once per repository, not per worktree.

Not Roost's to fix: on this Mac, tmux 3.6a shows non-ASCII window names as
underscores whatever the locale (tmux 3.7c on Linux keeps them); Roost's own
views show them correctly. Unloading a package also unbinds its settings, so
`unload-feature` followed by a reload returns Roost to its defaults.

### Outages, odd inputs and what Claude Code doesn't say, 2026-10-06

Another round in a copy of Clay's configuration with its own state, socket
and Emacs server, using Claude Code 2.1.289 and 2.1.292 (Haiku) for a few
short turns, the fake agent otherwise, and Claude Code's own bundle to check
what it does. To take a host away mid-session, that Emacs's ssh ran through a
ProxyCommand that could stop answering, for new connections and for one
already open, as a closed lid or a dropped network does.

- **A frozen Emacs.** With `claylien` out of reach, one request held Emacs
  for 10 s, ssh's connection timeout, then said "Output file descriptor of
  roost-rpc is closed". Requests went to ssh's standard input, and the
  helper, 73 KB, is more than a pipe holds; every failed poll also forgot
  the helper was installed, so each retry, about once a minute, sent it
  again. Input over 4 KB is now read from a file, and the helper is
  reinstalled only when Python on the host can't find it, as when another
  Emacs pruned it. The same request then returned in 1.4 ms and failed 10 s
  later with ssh's own message; a helper deleted on the host was reinstalled
  and the request answered. A shared connection that froze, as after sleep,
  cost nothing: ssh opened a new one.
- **Claude's transcript.** Claude names its project folder by turning every
  character but ASCII letters and digits into `-` (and hashes names over 200
  characters); Roost turned only `/` and `.`, so a task named `fix_notes`, or
  any worktree under a path with a space or an underscore, had no latest
  reply and no `ready` after Esc. Live, `fix_notes` showed its reply.
- **Prompts and names.** Claude read a prompt starting with `-`, such as a
  list, as an option and exited; it now follows `--`, and a two-item list
  came back "OK". A prompt in Russian or Chinese gave a name with no ASCII
  letters, which creation refused; the branch is now `roost/task-…`, accents
  fold (`cafe-menu`), and the name stays as written. A prompt over 120 KB,
  which Linux refuses as an argument, is refused before anything is created.
  A new repository with no commits, or a mistyped start, said "Needed a
  single revision".
- **What Claude doesn't report.** An approved command showed `permission`
  until it finished: Claude writes nothing, hook or transcript, until then.
  Claude runs it in a shell of its own as `eval 'COMMAND'`, so a listing now
  finds that shell and shows `running`; live, two seconds after approval. A
  minute after each turn Claude sends `idle_prompt`, which made an agent you
  had seen count as waiting again, live as `Roost:2` returning; it is now
  ignored unless the turn's end went unreported. A turn ended by an API
  error, such as a usage limit, said `s resumes`, which refuses a running
  agent; it now says why it failed and that RET opens it. Compaction, which
  Claude does by itself mid-turn, reported `SessionStart` and flashed
  `ready`; `/clear` and `/resume` reported `SessionEnd`. A background agent
  waiting for you (`agent_needs_input`) now counts as asking.
- **Git.** An agent that moved its worktree to a branch of its own could not
  be resumed (`s`) or given a shell (`t`); those now work, and merging names
  both branches. Untracked files in the primary checkout blocked merges;
  Git already refuses to overwrite one. A file whose name is not UTF-8,
  possible on Linux, made every full listing of its host fail, so the host
  looked unreachable.
- **Crashes.** Killing the agent (`kill -9`) showed `failed` with exit code
  −9 and a notification; killing the tmux server, `exited`. `s` resumed both
  into the same conversation, the second on a new server with extended keys
  on. Opening a remote task after an outage reconnected its terminal.

Agents keep reporting through the helper that launched them, so these
changes to status reach an agent once it is started or resumed with `s`.
The Python tests left a dead socket file behind for every test (6,816 on
the Mac, 313 on `claylien`); they now remove it. All 131 ERT and 89 Python
tests pass, on macOS and on `claylien`.

Not Roost's to fix: Emacs 30.2's server garbled long `emacsclient --eval`
results containing non-ASCII text ("*ERROR*: Unknown message"). Left as
they are: `roost-doctor` checks pushing for each project in turn, so many
projects with slow remotes can outlast its 60-second request; approvals of
Claude's other tools, and of Codex and Pi, still show `permission` until the
agent moves on.

### Codex and Pi adapters

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

### Limits

Physical laptop/network loss and restarting the entire GUI Emacs process were
not simulated. Client disconnect/reconnect, cache reconstruction, and persistent
host discovery were checked separately. Native QA used one actual remote host;
multiple-host behavior is covered by ERT. OS notification delivery was disabled
for the disposable sessions; notification selection/deduplication is tested.
Concurrent edits from unrelated external clients remain subject to normal Git
and tmux behavior. Roost relies on a narrow tmux-control connection API,
so changes to that API need integration retesting.
