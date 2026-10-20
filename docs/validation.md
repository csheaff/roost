# Validation

## Before a release

`make test` checks every view, button and key in batch, and `make qa` uses
Roost in a GUI Emacs with a fake agent; the manual's Development section says
what each covers. What only real agents, hosts and GitHub show needs a run by
hand. In a separate Emacs, as CLAUDE.md says, go through these and record what
happened in a section below:

1. Claude Code: `make contract`, then `make contract-live`, and for Codex and
   Pi `make contract-live CONTRACT_AGENTS="codex pi"`. Start a task from
   a draft and one from an Org heading. Answer a permission prompt in its
   terminal, interrupt a turn with Esc, and let one finish while you look at
   another: it waits in the sidebar, and `n` reaches it.
2. Codex and Pi: start a task with each, Pi with an extension that asks
   before each command. Send a prompt with `e`, answer a request, decline
   one and press Esc, with `roost-program-status` off and on.
3. A remote host: start a task over SSH, review it in Magit over TRAMP, write
   a note with `;` and send it with `@`.
4. Restart Emacs while an agent works: it is still at work, and `RET` brings
   back its terminal and panel.
5. Take a host away: the dashboard says it is unreachable and shows its last
   known state, and catches up once it is back.
6. Two tasks that change the same lines: each panel names the other task.
   Merge one, and the other says `conflicts`, naming the file, before you
   press `m`; on a remote host too. `u` in it brings the conflict into its
   worktree for its agent to resolve, and `m` merges it.
7. `P` opens a pull request; while its checks run and Copilot reviews it, the
   panel says so, and once they pass, the sidebar says `to merge` and `n`
   reaches it. Once it merges on GitHub, `x` retires the task. So does one
   the agent opens itself, and the sidebar then says `merged`.
8. Narrow and widen the frame, and open a second one: the sidebar and panel
   follow.

## Recorded sessions — 2026-10-19

`make contract-live` now keeps what each agent sent in `test/captures`, and
`make contract` scans Codex, Pi and OpenCode as it scanned Claude Code. Live
runs on the Mac, each passing every check:

- Claude Code 2.1.303, Haiku, with and without the OSC 7501 relay. Without
  it, a declined request and Esc reach Roost through no hook: the capture
  ends those steps at `permission` and `running`, and listings correct them
  from the transcript, as before.
- Codex 0.163.0, its default model, read-only with approval on request,
  with and without the relay. A fresh repository asks to trust it and then
  to review Roost's eight hooks, both before the task's prompt runs; the
  driver answers both, and afterwards puts back the tables of
  `~/.codex/config.toml` they wrote, leaving the rest as Codex left it.
  Relayed, a declined request reports `working` 85 ms before its `Interrupt`
  hook, so it shows as approved for that long. With Codex's memories on, its
  memory agent runs as a session of its own in the same Codex, in
  `~/.codex/memories`, and Roost's hooks report it too: its `SessionStart`
  showed the task ready in the middle of a turn, and its events took over
  the task's session. Roost now leaves out a Codex session whose `cwd` is
  outside the task's worktree, and the relayed capture shows the task
  running on its own session throughout.
- Pi 1.3.0 on LM Studio's qwen3.6-35b-a3b (49152 tokens of context): a turn,
  Esc and another turn.

The scans found nothing new in Codex 0.163.0 (twelve hook events, eight of
them Roost's, whose payloads it describes as JSON schemas in its binary), Pi
1.3.0 (41 extension events) or OpenCode 1.19.3. OpenCode also defines 28
`session.next.*` events for the engine it is moving to; the scan sets them
aside, and fails if the events Roost's plugin reads go. Codex's `Stop` now
carries `last_assistant_message`, which Roost could take as Claude's is
taken, rather than reading the rollout.

## Attachments — 2026-10-19

- **To `claylien` over SSH.** Ubuntu with Python 3.14.4, from Emacs 32 in
  batch, with a scratch state directory and a scratch task record. Roost
  installed its helper there and, in about a second for all four, attached a
  549 KB PNG twice, a Scrawl-shaped capture folder and the same image as a
  clipboard image. Each copy matched its original's SHA-256. The second PNG
  became `shot-2.png`. Of the capture, only `summary.md`, `scrawl.json`,
  `contact-sheet.png` and `frames/` went, not its 3 MB video or uncropped
  frames. The files were mode 600 and their folders 700. A plain folder was
  refused. Forgetting the task removed its attachments.
- **The same locally,** and on macOS the clipboard image came through as PNG
  bytes from `osascript`, as `the clipboard as «class PNGf»`.
- **`make qa`.** 150 steps, none with problems, with the new journey
  "Attach files to a prompt": `M-x roost-attach`, `C-c C-v` with a stubbed
  clipboard, `C-c C-a` with a capture, and sending. It and `send` pass with
  `--remote --popular` too. Its screenshots showed point left on the line of
  what was attached, where your words would run on from the path; an empty
  line you were on now stays empty below it.
- **Walking away from it.** The walk-away grid leaves a prompt draft with
  its file question open against each way of going to another task, locally
  and with `--remote --popular`: 7 more rows, none with problems, and the
  draft kept each time. Its shots showed the question opening in a remote
  task's worktree, over SSH; it now starts on this machine, where what you
  attach is.
- **Claude asks to read outside its worktree.** Claude Code 2.1.303 in
  `-p` with Haiku, `--permission-mode default` and only the project's
  settings, in a scratch repository, told to describe an image in a folder
  beside it: its Read was denied. With `--add-dir=` that folder, it described
  the image. So Roost now starts Claude with `--add-dir=` the task's own
  attachments folder, and `make contract` checks the option is there.
  `make contract-live` passed with it; one run alongside `make test` timed out
  waiting for an interrupted turn to be noticed, and passed when rerun alone,
  as `main` did.
- **Real Scrawl captures.** Two made with Scrawl on this Mac: one from its
  welcome tour, one recorded through computer use (TextEdit, a click, and a
  sentence spoken by `say` that Scrawl transcribed). They differed from
  what Roost assumed: the summary names the capture's folder on this Mac,
  and says the uncropped frames are in `frames-full/`, which Roost left
  behind. Roost now copies all of a capture but its video and audio (3.4 MB
  of this one's 12) and puts the copy's path in the summary. Attached on
  this Mac and on `claylien` with scratch state directories, the copies
  matched by SHA-256, and `M-n`'s newest capture was the new one. Claude
  Haiku, given the drafted prompt and `--add-dir=` the attachments, read
  the frames without asking and named the misspelling the speech pointed
  at. On `claylien`, Claude Code 2.1.304 did the same with `--add-dir`,
  and without it was refused the frames and asked for that option. The
  welcome tour's capture, 9.0 MB in 8 files, took 3.5 s to reach `claylien`
  over the home network, with Emacs waiting. Copied in the background since,
  `roost-send-attach` returned in 0.04 s, showing `[Copying …]`, and the
  path took its place 2.1 s later. Pen marks are untried:
  computer use can't draw on Scrawl's overlay.

## OpenCode and attachments — 2026-10-20

- **OpenCode asks.** OpenCode 1.19.3, installed in a scratch folder with its
  config, data and cache folders there too, and LM Studio's
  qwen3.6-35b-a3b at a 48k context. Told to read a file in a folder beside
  its project, `opencode run` asked `external_directory` for that folder,
  and turned it down unanswered. It has no option like Claude's
  `--add-dir`.
- **A rule after yours.** An `external_directory` rule in the inline
  config's own `permission` took the place of a one-word setting in the
  config files: `"external_directory": "deny"` became ask for every other
  folder. Given to each agent in the inline config instead, it still took
  the place of a word an agent had in the files. OpenCode calls each
  plugin's `config` hook with the config it merged from all of them, so
  Roost's plugin adds the rule there, to each agent, after what applied to
  `external_directory` before. Live: a file in the attachments folder, and
  one in a folder in it, were read without asking, while another folder
  stayed denied by `"*": "deny"` set after `external_directory`, and by an
  agent's own `"external_directory": "deny"` in the config file, or read
  where everything was allowed. Run with Roost's own plugin and
  environment, the attachment was read and another folder refused.
- **First runs stall.** In fresh folders OpenCode spent minutes fetching
  its tools before a first reply, which a short timeout cut off each time;
  once it had them, a run took about 12 s.

## OpenCode — 2026-10-19

- **OpenCode 1.19.3, from its source.** Plugins receive every bus event.
  `session.status` says `busy`, `retry` or `idle`; `permission.asked`,
  `question.asked` and their replies say what waits on you, in the
  session that asks, a subagent's included. The docs say
  `OPENCODE_CONFIG_DIR` adds a config folder, but 1.19.3 uses it in place
  of `~/.config/opencode`, hiding your settings, so Roost names its plugin
  in `OPENCODE_CONFIG_CONTENT` instead, which OpenCode merges over the
  rest, `plugin` lists included.
- **A live run.** OpenCode 1.19.3 installed in a scratch folder, its XDG
  folders there too, with LM Studio's qwen3.6-35b-a3b, driven through the
  helper on a tmux socket of its own. A task with a first prompt went
  `starting`, `ready`, `running`, `ready` with its reply and session. A
  command, with `bash` set to `ask`, showed "Asks to run ls -la" and
  `running` once allowed; declined, the task showed `interrupted`. So did
  Esc twice. The question tool showed "Asks: Which do you prefer?". A
  subagent's command showed as `permission`, and the task kept its own
  session. A wrong API key showed "Its turn ended on an error (APIError):
  invalid x-api-key" while OpenCode waited. `s` resumed the conversation.
- **Two things only the live run showed.** OpenCode says a session idles
  twice when you stop a turn, the second time without the error, which
  made it `ready` rather than `interrupted`: its plugin now reports one
  idle per turn. Declining a request ends the turn with no error at all;
  the plugin now says the turn ended on one you declined.
- **After review, the same setup.** OpenCode sets `busy` at each step of a
  turn; the plugin now reports it once. A request whose turn ends unanswered
  is dropped, as OpenCode drops one whose wait it interrupts with no reply.
  Esc on a command's approval showed `interrupted`. The agent ran
  `opencode run` from its shell: that OpenCode answered "nested", inheriting
  the plugin, and reported nothing, while the task stayed `running` in its
  own session until its turn ended.

## tmux-control's terminal interface — 2026-10-18

- **tmux-control main (34a6ec7).** tmux-control now uses Eat through one
  interface
  ([tmux-control#195](https://github.com/csheaff/tmux-control/pull/195)), and
  fits a window's buffer to its pane when the window's active pane changes
  ([tmux-control#200](https://github.com/csheaff/tmux-control/pull/200)).
  With it loaded, `check-declare` finds every tmux-control function Roost
  declares, taking the same arguments, and Roost compiles with no warnings.
  `make qa` on Emacs 32 with Eat 0.9.4, once the journey below was fixed: 142
  steps with no problems with `--remote --tuned`, and 147 locally with one,
  a pause noted below.
- **A journey that cut the connection too soon.** With `--remote`, `dropped`
  failed in all four runs, one of them on tmux-control 0.8.2. `open_task`
  waited only for the task's terminal, which Roost had shown already on
  creating the task, so it returned before the host replied to the open it
  asked for. The journey
  then cut the connection, and tmux-control said `C-c C-r reconnects`. Then
  the late reply put "Roost: opening hold-line…" in its place, and Roost
  reconnected the terminal. `open_task` now waits for the reply to its own
  open, and `dropped` for the agent's screen before it cuts the connection.
- **Seen once, not since.** Opening a draft from an Org heading over
  `--remote` stalled Emacs for 19 seconds, and going back to a split task
  once said "tmux kept the window at 142x36 (asked 98x16)". Neither came back
  in reruns of those journeys on tmux-control 0.8.2 and main: 5 runs each of
  `panes`, and one each of `frames`, `org`, `tabs` and `dropped` over
  `--remote`. Locally, opening `plans.org` once took 1.12 seconds, over the
  pause limit, and less in three reruns.
- **A dropped terminal hides the agent's last screen.** Once the connection
  goes, tmux-control writes its notice after the whole screen, blank rows
  included, and shows the end: the agent's lines scroll out of view above
  it. tmux-control 0.8.2 does the same.

## Conflicts before merge time — 2026-10-17

- **`make qa`.** 147 steps, none with problems, with Git 2.54. The new
  journey: two tasks commit one file and each panel names the other; once
  one merges, the other says `conflicts` in the sidebar and "Conflicts with
  main in SHARED.md" in its panel, with main untouched; `u` brings the
  conflict into its worktree, aborting it brings the warning back, and
  resolving it clears it.
- **`n` beside a blocked task.** The first full run left that journey's task
  in `conflicts`, and the pull request journey's `n` then never reached its
  `to merge` task: with one task asking for permission, `n` goes back and
  forth between it and the next waiting task only. The journey now resolves
  its conflict; `n` itself is a separate fix.
- **Not checked live:** a pull request GitHub finds conflicting. Its
  `mergeable` comes from the query #60 checked live; only the status word
  is new.

## A pull request waiting on you — 2026-10-16

- **Copilot's pending review.** On #60, right after Copilot's review was asked
  for with `gh pr edit --add-reviewer @copilot`, the helper's GraphQL query
  listed `copilot-pull-request-reviewer` as a review still to come, while
  `gh pr list --json reviewRequests` (gh 2.88.1) listed none. A pull request
  with Copilot still reviewing is therefore not `to merge`, which it would
  have been had the helper read `gh pr list`. #58 and #59 had Copilot's
  review asked for seven seconds after they opened; #60, opened with
  `gh pr create` alone, had none until asked.
- **Review threads.** Against #46 and #54, whose Copilot threads were all
  resolved before they merged (11 and 7), the query counted none unresolved.
- **`make qa`.** The new journey passes locally and with `--remote`: a pull
  request from `P`, then GitHub still at work, `to merge`, `n` reaching it,
  `ci failed`, `comments`, and its merge.

## Merged at a glance — 2026-10-13

- **A pull request Roost didn't open.** Against this repository on GitHub, the
  helper's own lookup for the branch `status-lights` found #12, squash-merged
  and its branch deleted there: `gh pr list --head` still lists it, with the
  branch's local tip as its head. The task counted as merged, and retiring it
  had GitHub's proof, where before it would have refused for unmerged commits.
- **Merged outside Roost.** In `make qa`, a task whose commit reached main by a
  merge made in the primary checkout said `merged` in the sidebar and panel,
  and `x` asked only whether to retire it. A task with no commits that `u`
  fast-forwarded to main first said `merged` too; the task branch's reflog now
  has to show a commit made on it.

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

### A session per task, 2026-10-07

Each task now has a tmux session of its own, `roost-PROJECT-ID`, holding
only its agent's window (and the shell beside it), so stopping or retiring
the task ends the session and, with the last one, the tmux server. Checked
in the copy of Clay's configuration against `claylien` (tmux 3.7c) and the
Mac (tmux 3.6a) with the fake agent, which runs Claude's hook commands:

- **Closing terminals.** Roost disconnects a task's terminal before asking
  its host to stop, resume, retire or merge it, as the session would end
  under it. A stopped task then left a blank, disconnected terminal on
  screen; it now goes once the host has acted. When the host refused, as
  it does to retire unmerged work, the agent ran on behind a dead
  terminal; that terminal now reconnects, once the host confirms the
  agent's window is still there (tmux-control attaches with
  `new-session -A`, so reconnecting to an ended session would start an
  empty one). Live: a refused retire reconnected with the agent's output;
  stop, merge and retire left no terminal, no message and no tmux server.
  Roost also disconnected through a scrollback view, if that came first,
  which holds no connection of its own.
- **Crashes and lost links.** Killing `claylien`'s tmux server marked the
  task `crashed` with a notification; RET offered to resume it, and `y`
  resumed the same conversation. Killing a terminal's ssh, as a sleeping
  laptop does, left a terminal that RET reconnected. tmux numbers panes
  afresh after its server restarts, so a crashed task still listed the pane
  ID of a newer task's agent: commands run from the newer terminal could act
  on the crashed task. Terminals are now matched to tasks by session too.
- **The sidebar.** Point may rest on a project's heading, where `c` starts
  a task; a redraw, which follows every poll, moved it to the top (and the
  dashboard's to its first task), and a click on a heading jumped to a task.
- **Git.** An agent that checked out submodules, as one does to build,
  left a worktree Git will not remove; retiring stopped the agent and then
  failed. It now refuses first, saying how to remove the worktree.
- **tmux 3.7** keeps `:` and `.` in a session's name, which 3.6 turned into
  `_`, and then cannot find the session by name; a chosen session name
  (`roost-session-name`) is now changed as before.

Claude Code 2.1.293 (Mac) and 2.1.289 (`claylien`) pass `make contract`.
All 139 ERT and 95 Python tests pass, the Python ones on macOS and on
`claylien`.

Not Roost's: after its session ends, a tmux-control terminal says both "tmux
session ended" and "connection lost … C-c C-r reconnects", and that
reconnect would start an empty session of the same name.

### After a design review, 2026-10-08

A review of Roost as a whole found actions offered that the host would
refuse, attention that forgot agents and restarts, and gaps around ending a
task. Changed and checked in the copy of Clay's configuration, with the fake
agent on `claylien` (tmux 3.7c, Git 2.51) and the Mac (tmux 3.6a, Git 2.54):

- **What a task can do now.** The panel lists only actions that apply and
  leads with the next step; a stopped task's offered "RET or s resumes its
  conversation" and Resume, without Shell, Send or Stop. The command menu,
  with Clay's transient 20261001, greyed out Stop, Send and Shell for it.
- **Waiting and seen.** Failed, crashed and exited agents count as waiting
  until seen. Opening a remote task recorded `seen` in its record on
  `claylien`; with Emacs's own record of it cleared, as after a restart or
  on another machine, it still counted as seen.
- **Ending a task.** Discarding a task holding a commit and an untracked
  file named both and wanted the name typed; its window, worktree and branch
  went. With `claylien`'s checkout on another branch and an edit in it,
  merging a task put a merge commit on `main` and left the checkout and the
  edit alone.
- **An agent's own worktrees.** Claude Code 2.1.293 made a worktree with
  `--worktree` in the primary checkout's `.claude/worktrees`, from the
  default branch; with `worktree.baseRef` "head" in `--settings`, from the
  task's commit; its hooks reported that worktree as `cwd`. On `claylien`,
  a hook from such a worktree listed it in the task's panel with its commit,
  and retiring was refused, naming it.
- **Getting there.** Running a notification's click command opened its task
  in its workspace. With tmux-control#165, "next session" from one task's
  terminal opened the other task, in its own workspace.

`make contract` passes with Claude Code 2.1.293 and checks `cwd` and
`worktree.baseRef` too. All 148 ERT and 103 Python tests pass, the Python
ones on macOS and on `claylien`. Left alone: renaming tasks, a log of
retired ones, and polls that wait for a change, which slower polling
while Emacs is in the background makes less needed.

### A second design review and bug hunt, 2026-10-08

Checked live with the fake agent on `claylien`, in the copy of Clay's
configuration:

- **x finishes a task.** On a task with an unmerged commit, `x` offered to
  discard it, then named the commit and that the agent would be stopped,
  and wanted the name typed; worktree, branch and window went. On a task
  whose work was merged it retires, after asking.
- **error.** A `StopFailure` (a usage limit) on a running agent showed
  `error` in the sidebar, panel and notification, with "Open it to try its
  last prompt again", and counted as waiting, in red.
- **The agent's own worktrees.** Merging a task whose agent had left an
  empty, locked worktree removed it and its branch. Discarding counts and
  removes them; a task whose agent moved its worktree to a branch of its
  own can be discarded, keeping that branch.
- **A merge under way.** Declining to have the agent resolve an update's
  conflict left it in the worktree; the panel now says so ("Merging main
  into it conflicts in ledger.py") and leads with finishing it in Magit.
- **Merging without a checkout** wrote "Merge branch 'roost/…'", as Git
  2.51's own `git merge` does (from `git fmt-merge-msg`).
- `roost-doctor` reported notifications through osascript and how to get
  ones that open their task.

Found in review and fixed: watching a working agent sent its host a `seen`
request at nearly every poll; forgetting a task in `error` didn't stop its
agent first, so the host refused; the next step told you RET resumes an
exited agent; `x` could retire without asking; a poll in flight brought a
forgotten host's tasks back. All 154 ERT and 107 Python tests pass, the
Python ones on macOS and on `claylien`.

### Review notes in Magit, 2026-10-09

Checked live in the copy of Clay's configuration, on a local task with the
fake agent, and later the same on `claylien` over tramp-rpc, the TRAMP method
Clay's configuration uses. There `r` opened the remote status in 1.3 s and
a refresh took 0.36 to 0.38 s; notes, `@` and `=` behaved as below:

- **Notes.** `;` on an added line, a file's name and the last line of a hunk
  wrote notes that show under those lines, in their own face rather than the
  diff line's colours, and fold away with their hunk. One written in the
  whole-file diff showed in the status too.
- **Sending.** `@` drafted a prompt with the three notes in the order written,
  each quoting its line, with a line free at the top. With a few words added,
  `C-c C-c` pasted it all into the agent, closed the draft and cleared the
  notes, on disk too.
- **The whole file.** `=` on `greet.py` in the status opened its unstaged diff
  as one hunk of all 28 lines, in the other window, as Clay's
  `magit-display-buffer-function` puts diffs.
- **The status** named the task and folded the agent's reply into one line
  that fits the window. The panel said "1 review note for the agent; e sends
  it".

Found while checking it: two notes ending on one line came out in no
particular order (now one overlay, oldest first); a note placed after its
line took that line's background, and its bar came out slanted in an italic
face. Typed keys in the QA Emacs went to xah-fly-keys' command mode after the
first note's prompt closed, as after any prompt in Clay's configuration; Magit
keys need insert mode there anyway. All 165 ERT tests pass with Magit on the
load path; without it the four Magit ones are skipped.

Then, for what most Emacs users would expect: the task panel became opt-in,
like the sidebar; the status's task line lost the agent's status, which went
stale between refreshes, and says what the task merges into instead;
`roost-magit-status-sections` turns the task line and the reply off; and with
Evil the keys work in normal state, the whole-file diff on `g=` because
evil-collection binds `=` to less context. A test loads Evil (MELPA,
2026-07-28) and evil-collection's Magit bindings and checks each key, and
that `=` and `gr` stay evil-collection's. 166 ERT tests pass with Magit and
Evil, 165 with Magit alone (the Evil one skipped), 161 with neither.

### A hands-on design review, 2026-10-09

Used as an Emacs user who already runs Claude Code in a terminal would: a
plain configuration (Vertico, Marginalia, Orderless, which-key, Magit,
`modus-vivendi`), Roost set up as the README says, and three real Claude Code
tasks (Haiku) taken from prompt to merge, one on `claylien` over TRAMP's
default `scp` method, with an update that conflicted and an Emacs restart.

What sped the work up: a task running 6 s after `C-c C-c` (10 s remote); a
notification naming the command an agent wanted to run, and `n` landing on
its prompt; a declined prompt turning the task `ready` within seconds; the
agent's reply, with the choices it made, above its diff in Magit; two notes
sent with `@` and fixed in 8 s; `m` merging and removing the worktree and
branch in about 6 s, and reverting the open file; the agents still there 6 s
after restarting Emacs.

What got in the way, and what changed:

- **A new task ignored where you were.** The draft worked out its default
  project after switching to its own buffer, so it offered "Choose a
  project…" from inside a checkout, and from a region in one project it
  defaulted to another on `claylien`. It now looks where you are, in Dired
  or a shell too, and the picker adds `project.el`'s projects.
- **An interrupted turn looked finished.** It showed `ready`, with the
  agent's last words ("Next I'll check…"). It is now `interrupted`, and the
  next step says to tell the agent what to do instead.
- **`u` stopped at uncommitted changes.** It now offers to have the agent
  commit and update, as it did for conflicts; told so by hand, the agent
  committed, merged `main`, resolved the conflicts and ran the tests in 25 s.
- **Merge commits piled up.** `roost-merge-style` set to `squash` brings a
  task in as one commit, with the task's commit messages.
- **Remote review is slow over TRAMP's shell methods.** Magit took 3.6 s to
  open the remote task (19.6 s on a cold connection) and 1.7 s to refresh or
  stage, against 0.4 s with tramp-rpc. `roost-doctor` now names the method
  and the README says what to expect.
- With no tasks, the menus offered task commands; they are greyed out.

Left as they are: Claude Code's folder-trust prompt, once per project and
host, defaulting to "No, exit"; Magit's "Error showing commit diff" when
committing over `scp`, which the commit survived. 177 ERT tests pass with
Magit and Evil, and 110 Python tests.

### A code read, and an Evil user with twenty tasks, 2026-10-10

A read of all of `roost.el` and the host helper, then a plain Evil
configuration (evil-collection, Vertico, `tab-bar-mode`, Roost loaded
uncompiled, as in the author's Emacs) driven with real key events: twenty
fake-agent tasks in two projects, and one Claude Code task (Haiku 4.5,
2.1.293, manual permissions) to check a notification. `make contract`
found Claude Code reporting what Roost reads.

What worked: `j`/`k` and `RET` in the dashboard; typing straight into the
agent (insert state); the menu from a terminal on a global key, naming its
task; `n` across tabs; `x` on a task with no work, closing its tab;
twenty tasks readable in the dashboard and sidebar; a full refresh of
twenty in 1.7 s on the host, a quiet poll in 0.1 s.

Found and fixed:

- **A selection didn't survive the next poll.** Every poll redrew the
  task panels and the dashboard, which moved the mark to the top: a
  selection of part of the agent's reply became the panel from its
  heading down, and copying it copied that. The mark now stays where it
  was.
- **Panels nobody saw were redrawn too.** Every panel opened with `i`
  stays, and each was redrawn at every poll, 3 seconds apart: 25 ms with
  seventeen tasks, uncompiled. A panel or dashboard no window shows is
  now redrawn once one does: 10 ms, with the sidebar and one panel shown.
- **Retiring held up every agent on the host.** Retire, merge and discard
  removed the worktree while holding the lock each agent's hooks wait on
  at every event. A worktree with 30,000 ignored files (117 MB, as
  `node_modules`) held it 1.3 s; dependencies ten times that size would
  hold the agents ten times as long, and Codex gives a hook 3 s. Worktrees
  are now removed without the lock (0.17 s). Meanwhile a lock of the
  task's own, which Git inherits, keeps everything else off the task, a
  retry after Emacs gave up waiting included, until Git is done.
- **Finishing a task could pull its worktree from under a push.** `P`
  pushes and asks GitHub without the lock, for seconds; a retire, merge or
  discard meanwhile deleted the worktree the push was running in, or the
  record the new pull request was then saved in (Copilot's review found
  it). `P` now holds the task's own lock too, shared, as do the Git and gh
  it starts, and finishing the task waits, before its agent is stopped.
- **An agent that asked at once didn't notify.** From `starting`, only a
  finished turn notified. With Emacs in the background, polls are 15 s
  apart, and a task started with a prompt usually asks within that: the
  first poll saw `permission` and said nothing. It now notifies, as it
  does for a CLI that fails at once; the real task's notification read
  "Asks to run python3 contract_check.py".
- `x` now says what it removed, `M-x roost-retire` is autoloaded, and the
  README says how an Evil user stops an agent's turn, which Claude Code
  does on ESC: `C-c C-c`, or evil-collection's `C-c C-z`.

Left as they are: a task `n` opens stops counting as waiting once you
have seen it, so the next `n` starts again from the most urgent task
rather than the one after it; the dashboard, in Emacs state, has no `/`
or `:`.
179 ERT tests pass with Magit and Evil, and 113 Python tests.

### Agents that report their status, 2026-10-10

Claude Code 2.1.295 added the Program Status Protocol (OSC 7501): it tells
a terminal that answers its probe whether it works, waits on you or is
done. Inside tmux it tells nothing, since tmux answers only the device
attributes query sent after the probe (Claude Code 2.1.296, tmux 3.7c;
tmux/tmux#5713 asks for support, and its maintainer would rather wait).
With `roost-program-status` on, the runner relays the agent's terminal and
answers.

One Haiku task on the Linux host, manual permissions, with each report and
hook logged with its time:

- An approved `touch … && sleep 6` showed `running` 0.17 s after Return;
  hooks said nothing until the command ended, 6 s later.
- A request declined with Esc, and a long reply stopped with Esc, showed
  `interrupted` within a second, with no hook and no transcript read.
- Reports came 20 to 70 ms ahead of the matching hook, but the Stop hook
  came 20 ms before `done`. So while an agent reports, hooks no longer set
  its status, only what they know besides: the conversation, transcript and
  reply, the request's wording, work left in the background, an API error.
- Claude's own words for a request ("approve Bash: touch relay-proof.txt
  && …") are used when no hook names it; its description of the step under
  way is recorded as `activity`.
- Resizing (64 and 100 columns), Shift+Return, stop (no process left
  behind), resume and `/exit` (exited, 0) work as before. Nothing is
  reported while Claude asks whether to trust the folder.
- The runner used 0.09 s of CPU in two minutes in which Claude used 6.5 s.
  Relaying 21 MB of `seq` output took 0.87 s of CPU, and no longer than
  tmux alone.

Left: Codex reports nothing yet, and Pi says it will in its next release;
records Claude keeps for subagents are ignored. The ERT tests (Magit and
Evil ones skipped here) and 125 Python tests pass on macOS and the Linux
host.

### Status lights that move, 2026-10-10

Emacs 32 draws canvas images: pixels that Lisp writes and redraws in
place. With `roost-animations` on, the status light of an agent asking
you something pulses and one whose turn ended unseen glows; the rest
stay still. In a `-Q` Emacs 32 on macOS with six made-up tasks, one in
each state, and Roost uncompiled, as Clay runs it:

- A canvas has no transparency: unpainted pixels show black, so each
  light paints its background. In the sidebar the lights sit in the left
  margin (the `margin` face, Emacs 31 and later), where no highlight
  covers them; in the task panel and mode line they take the dot's place.
- A scaled canvas drew only a quarter of itself, and `create-image`
  scales by default (`image-scaling-factor` forced to 2 doubled a light to
  32×30 and made rows taller), so lights are made with `:scale 1`.
- Canvases ignore `:mask` too. The task panel's light, in the text of its
  first line, repaints its background while the selection highlight is on
  that line, and the mode line's light shows only in the selected window,
  whose background it paints.
- A first version, which moved working agents too, drew 12 frames a
  second and used 10% of a core: a closure made for every pixel. Plain
  arithmetic, distances cached per size and a redraw only when a light's
  motion takes one of its 16 steps brought that to 3%; compiling didn't
  help, since redisplay cost the rest. Agents at work rest now, so motion
  means an agent needs you. With two waiting, Emacs used 2% of a core;
  with none, the timer stops and it used 0.01 s of CPU in 20 s.
- Motion pauses while no Emacs frame has focus, and only lights in a
  visible window are redrawn. The mode line's light goes when nobody
  waits, and a task panel forgets the light of the task it showed before.

Elsewhere (Emacs 29 and 30, a terminal, or the option off) a light is
the dot it was, and the ERT tests stand in for canvases.

### A full configuration on Emacs 32, 2026-10-10

The author's daily Emacs became Emacs 32 (32.0.50, emacs-plus master)
the same day; CI tests 29.1 and 30.1. The suites ran on 32 first, then a
copy of the author's configuration (xah-fly-keys, Vertico, perspective.el,
modus-vivendi, global line numbers and `visual-line-mode`, Roost
uncompiled) with its own server, state and tmux socket, driven with real
key events: fake agents here and on claylien, and one Claude Code task
there (Haiku 5.5, 2.1.296) taken from prompt to review notes, a commit in
Magit over TRAMP's rpc method, and merge. tmux-control's 331 tests pass
on 32 and it compiles without warnings.

What worked: the menu from a terminal (`Esc SPC s`), naming the task and
the next step; the folder-trust prompt counted as waiting after 15 s;
permission requests through program status, approved and declined; a
notification naming the command; session search, a retired task's
conversation included; a review note sent with `@` and applied; stop,
resume and finish; the sidebar and panel through `C-x 1`, a narrow frame
and back.

Found and fixed:

- **A test failed on Emacs 32, and host errors could end in a stray
  line.** For a request's stderr, Emacs makes a pipe that notes "Process
  roost-rpc stderr finished" when it closes, and Emacs 32 can read that
  before the request does. Requests now make their own pipe.
- **Status lights sat on gray squares.** modus-themes gives the margin
  face the fringe's background, and with no fringe color it has none, so
  each light painted the fallback gray. A face without a background shows
  the default one, and lights now paint that.
- **Search results showed line numbers, and wrapped.** Global
  `display-line-numbers-mode` and `visual-line-mode` reached the search
  buffer, which came after the others were kept from them, and wrapping
  left TAB nothing more to show. The setup check had line numbers too.
- **A view that failed to draw stopped all polling.** An error drawing a
  list reply (a search buffer made inconsistent while testing) was taken
  for the host's failure, so every host showed "offline"; drawing again
  failed again before the refresh ended, so no host was asked again until
  Emacs restarted. A callback's error is now Roost's, and refreshes always
  end.
- **Moving lights cost CPU with Emacs in the background.** Their timer
  ran twelve times a second whether or not a light was due to move, and in
  this configuration each wakeup costs a redisplay: a timer doing nothing
  at 12 Hz used 2.9% of a core. With two agents asking, lights used 3.3%
  with Emacs in the background, where they don't move, and 6.3% in front.
  The timer now wakes when the next light is due to move, ten times a
  second for a pulse, and once a second while no frame has focus: 0.4%
  in the background (0.55% without lights) and 5.8% in front. Drawing is
  cheap (1 ms for six lights, uncompiled); the rest is redisplay.
- **Pickers lost their order.** Vertico sorts a plain list by length,
  which put "Other directory…" above the projects used last; the project,
  agent and issue pickers now keep their order.
- The setup check ran a long name into its detail ("Push · qa-projectno
  origin remote"), and sending, stopping, resuming and opening a shell
  said "Roost mean: send" where other actions say what they did.
- `make contract` on 2.1.296 found a new notification type,
  `plugin_notification`, a plugin's message through its `ui.notify`. Roost
  ignores types it doesn't map, so status was right; the scan knows it now.

Not Roost's: Magit's commit message shows "Error showing commit diff" in
any linked worktree over TRAMP, as every remote task is. In the worktree's
Git directory, `magit-toplevel` returns the working tree's path on the
host without the TRAMP prefix (the commit itself works). In the author's
configuration, a minibuffer prompt in Magit, such as a review note's,
leaves xah-fly-keys in command mode, where `;` isn't `roost-note`.

193 ERT tests pass on Emacs 32 with Magit (and on 30 without it), and
139 Python tests.

### A new user's first hour, 2026-10-10

The rounds before used the author's configuration. This one used none:
Emacs 30.2 with a fresh `--init-directory`, Roost and tmux-control
installed with `use-package :vc` from GitHub as the README says, Magit
from MELPA, fido, and no Roost settings but the hosts. In a throwaway
project, two Claude Code tasks (Haiku 5.5, 2.1.293, asking before each
command) worked at once on the same function; one committed, one left its
change uncommitted. The first was merged, which put the second behind
with a conflict; `u` had its agent commit, merge main, resolve the
conflict and pass the tests, and the second was merged too. A third task
was stopped and retired.

What worked: the setup check, the draft finding the project, `n` from
terminal to terminal, the agent resolving a real conflict on the first
try, merging with its cleanup, and the sidebar, terminal and panel side
by side.

Found and fixed:

- **Work the agent committed had nowhere to be reviewed.** `r` opened
  Magit's status with only a folded "Recent commits": a task's branch has
  no upstream, so Magit has nothing to call unmerged. The status now lists
  the commits not yet in the integration branch (`Unmerged into main`),
  and `RET` on that heading shows their changes together.
- **After a restart, Roost said nothing until opened.** Watching starts
  with the dashboard, the sidebar or a new task, so agents still at work
  went uncounted and unannounced, and Magit lacked Roost's keys. The
  install snippets now turn on `roost-watch-mode`, and the setup check
  says whether it ran from the start.
- **No way to Roost from where you work.** In an agent's terminal every
  key but `C-c` and `C-x` goes to the agent, and a plain configuration
  binds no Roost key, so it was `M-x` every time. `C-c ?` there, and in
  Magit on a task, opens the menu.
- **Two small tasks left three merge commits.** `m` made a merge commit
  for each task, and `u` had made one in the task, so main read
  `Merge branch 'roost/add-top-n-option-0e40ec'` around a merge of main.
  `roost-merge-style` now defaults to `squash`: one commit per task with
  its commits' message, and the updates gone.
- **Typing `yes` for things that lose nothing.** Stopping (which keeps
  everything), updating (which sends the agent a prompt), merging and
  retiring a task with nothing to lose wanted `yes`; the author's
  configuration answers every question with one key, so it never showed.
  They ask `y` or `n`; discarding work still wants the task's name.
- **A finished task's panel stayed.** It said the task had been retired
  and kept half the frame, which kept the next task's panel from docking.
  It closes with the task now.
- **Reading the reply didn't count.** Only the terminal marked an agent
  seen, so after reading its whole reply in the panel, `n` went back to
  it. A panel in the selected window counts now.
- **Requests began with the worktree's path.** The dashboard showed "Asks
  to run cd /Users/…/worktrees/5b12cd8500/add-top-n-option…", as Claude
  Code often starts a command with a `cd` into the directory it is already
  in. That `cd` is left out now, and paths in the worktree are relative.

Not changed: names made from prompts can read oddly ("when a file named
on the command line…" became `when-file-named-command`; Claude Code
writes no title of its session to borrow), and a dashboard half a frame
wide leaves about ten columns for the reply.

The changes were checked again in a plain Emacs 32 loading this branch:
the setup check, `C-c ?` in a terminal, a committed task reviewed through
`Unmerged into main`, and `m` squashing it into one commit and closing
its panel. Of 199 ERT tests, 198 pass on Emacs 32 with Magit and one
is skipped without Evil; 139 Python tests pass. The six new ERT tests
fail against the code before them, and a test session now fails rather
than waits on a question no test answered.

### The task panel beside the terminal, 2026-10-12

A survey of other tools' side panels (Claude Code's agent view, Codex's
review pane, Conductor's Checks tab, Cosine's side panel, Pentagon, workmux)
found the column beside one agent holding what its terminal doesn't show:
the goal, the Git and pull request state. Replies show in lists of agents,
and actions behind a key. The panel had led with the agent's latest reply,
which the terminal beside it already showed, and ended with a list of every
action, which `?` already opens.

Tried in a plain Emacs 30.2 (Magit, tmux-control from its main branch,
the sidebar and the panel on, no workspaces), with Claude Code 2.1.296 and
`--model haiku`, asking before each command. A local task added a
`search` command and its test. From the panel, `RET` on `notes.py`
opened its diff above the terminal, which stayed in view; `;` on a line
wrote a note, the panel counted it, `@` drafted the prompt, `C-c C-c` sent
it, and the agent made the change and ran the tests. Committing the test
by hand moved it under "Committed", with the edited file still under
"Uncommitted". On `claylien`, a task held at folder trust had a commit, a
staged rename, an edit and a new file made in its worktree over SSH; all
three files showed under "Uncommitted", and a note written in the
renamed file's diff, opened from the panel through TRAMP, was counted.

Found and fixed:

- **Docked didn't mean beside the terminal.** With the dashboard in the
  main area and the panel docked, `i` selected the panel, which left out
  the reply though no terminal showed it. The panel now leaves the reply
  out only while the agent's terminal is on screen, and redraws when it
  comes or goes.
- **The same advice twice.** With the next step at the top, the notes
  lower down repeated it for an agent at a startup prompt, one whose turn
  failed, and one that exited. Those notes are gone; the startup prompt's
  next step names folder trust, and the failed turn's says it failed.
- **"Uncommitted" twice.** The summary said "· uncommitted" over the label
  that says it per file; in the panel the summary leaves it out.

Not changed: a renamed file's diff, limited to its new path, shows the
whole file as new, as before; the panel's mouse use wasn't tried, since
the capture had no screen access; and docked beside the terminal, the
panel now leaves much of its column empty.

All 225 ERT tests pass on Emacs 32 with Magit and Evil, and 141 Python
tests pass.

### A question left open, 2026-10-14

On another machine (Emacs 31, perspective, vertico-posframe, recursive
minibuffers, hosts `dev` and `nebius-0`), clicks on tasks in the sidebar
did nothing until Emacs restarted. That Emacs had `Task: ` questions
open in the minibuffer, none on screen.

Tried in a `make qa` Emacs 32 with vertico, vertico-posframe and
perspective added as in that configuration, and two tasks. With `M-x`
open, a click on the other task's row hid the popup within half a
second and the minibuffer window stayed scrolled out of sight, so the
question was gone from the screen but still open. The task waited for
it, as Roost holds a task back until the minibuffer is done; more clicks
did the same, and `C-g` in the sidebar left the question open. A message
saying so didn't show either. Showing the task anyway was no answer: a
perspective switch left the mini-window on another minibuffer, and
quitting the question then restored the windows it had found, with the
first task's terminal in the second task's perspective.

Opening a task from a Roost command now quits the questions you left
open first, then opens it, and asks which task only after. Tried with
one and two questions open, with a click, `RET` and `t`; each opened
the task in its perspective, with its panel, and said what it quit. The
new `question_left` journey, a click and then `l` with `M-x` open, fails
without the change and passes with it, with and without vertico-posframe;
without recursive minibuffers, `l` had failed to ask.

Not found: what opened the first `Task: ` there, and why clicks added
more. Here a click found its row each time; `RET` or another task key on
a project heading asks `Task: `.

### Leaving things unfinished, 2026-10-14

Why the question left open (above) went unseen by the tests: the sweep
answered every question at once, every journey answered or cancelled
what it opened, `make qa`'s Emacs had no completion popup or
perspectives, and no check failed a click that did nothing. Each step of
`make qa` now fails a question open that you aren't in, unless the
journey left it so, and anything Roost holds back until such a question
is done; the sweep fails a click on a task's row that asks in the
minibuffer, the task listed or gone since. With the change above taken
out, both fail: the sweep with `Task: ` asked by a click on a gone task's
row, and `make qa` in 17 steps, each saying "Roost holds 1 back until
questions you aren't in are done", where only a timeout had said so.

The new `walk_away` journey leaves six things unfinished (`M-x` open,
`M-x` left behind in a terminal, Roost's `Switch task: `, its menu, a
draft, a task whose host hasn't replied) and then goes to a task six
ways (a click, `l`, `n` and `t` in the sidebar, a click on a
notification, a click in the terminal). `--popular` adds vertico,
vertico-posframe, recursive minibuffers and perspective.el. Run plain,
with `--popular`, and with `--popular --remote`, the whole of `make qa`
in the last, it found:

- With `M-x` left behind in a terminal, a click on a notification held
  its task back unseen, as clicks in the sidebar had. Fixed: the click
  quits the question once Emacs is waiting for you, not from the
  server's reply, which can come while a command waits.
- With perspectives, closing the second frame left the sidebar marking
  its task. Fixed: closing a frame draws the sidebar again.
- With Roost's menu open, a click on a task in the sidebar only says
  "Unbound suffix: `<mouse-1>`". Fixed after: a click on a task's row
  closes any menu and does what it does.
- With perspectives and the tasks on `qa-remote`, a shell pane opened
  again with `t` shows a line or two of history for a second or more:
  the perspective restores the window's start from the last visit, after
  the pane has scrolled since, and tmux-control anchors a split view's
  window to the screen's top only when output comes. Fixed after, in
  tmux-control, which now anchors it when it comes back: with that
  tmux-control, the shell pane started at its screen's top on each of
  four visits, a second after `t`.
- With perspectives, a frame made with `C-x 5 2` shows the task's
  terminal in a perspective of its own, which is no task's, so it has no
  panel. Fixed after: a workspace that is no task's follows the task
  whose terminal it shows.
- A click on the perspective bar's `Roost:` entry asked `Switch task: `
  in the minibuffer, the question a popup hides once you click
  elsewhere. Fixed after: it shows a menu at the pointer, as the
  project's choice does.

### Codex and Pi as surely as Claude, 2026-10-16

Codex 0.163.0 and Pi 1.3.0 on the Mac, with tmux 3.6a. Each ran first under
the runner's relay alone, every report and hook logged with its time, then
as a task in a separate Emacs 30.2 with its own state directory, tmux socket
and project.

What they report:

- Codex reports OSC 7501 whenever its output is a terminal, with no probe,
  and only `idle`, `working` and `blocked`, then `clear` at exit. It reports
  nothing while it asks to trust the folder and the hooks, then idles, works
  for about a second (its servers starting) and idles again, before any
  prompt.
- A finished Codex turn's Stop hook came 15 ms before `idle`, and an Esc's
  Interrupt hook 3 ms before it. A declined request went `blocked`,
  `working`, Interrupt hook, `idle`. An approved command showed `working` at
  once, and its PostToolUse hook came when it ended, 4 s later. With a
  command left running in the background, no `idle` came after the Stop
  hook until that command ended.
- Pi answered the probe and reported `working`; `blocked` with
  `kind=permission` and the title of an extension's confirm dialog; `done`;
  and `idle` after Esc. Its extension events `ui_prompt_start` and
  `ui_prompt_end` came in the same millisecond as `blocked` and the
  `working` after it. Esc gave `agent_end`, then `agent_settled` with
  `aborted`, then `idle`.

Before the fix, a relayed Codex task showed `interrupted` right after it
started, and again after a turn that finished: Roost took `idle` after work
for Esc, and set the Stop hook aside. Now Codex's hooks say when its turns
start and end, and its reports add an answered request, a question no hook
names, its start, and a turn that ends without its hooks.

Tasks in Emacs:

- Codex (gpt-6.1-sol, low effort), relay on. It asked to trust the folder,
  then to review Roost's eight hooks, while the panel said to answer in its
  terminal. It began the task's prompt with its hook browser still open, and
  until the hooks were trusted the task showed `ready` while Codex worked;
  from its first tool call it showed `running`. Its request to commit (its
  sandbox keeps `.git` read-only) showed `permission`, "Asks to run git add
  greet.py test_greet.py && git commit …", and declined, `interrupted`. A
  prompt sent with `e` asked again; approved, `running` within a second, and
  the turn ended `ready`, its reply in the notification. Esc mid-turn:
  `interrupted`. `K` and `s` resumed the same conversation, `ready` within a
  second, and a turn after it ended `ready`. `m` squashed it into main and
  removed its worktree and branch.
- Pi, with its own configuration: qwen3.6-35b-a3b in LM Studio, no API key,
  and an extension asking before each bash command. Relay off. Each dialog
  showed `permission` ("Run this command?") and, answered, `running`; Esc at
  a dialog, `running`, and Esc again, `interrupted`. LM Studio had loaded the
  model with an 8k context, too small for Pi's prompt, and it went round in
  circles. Reloaded at 48k for the run, it added `farewell` with a test, ran
  the tests and committed. A declined command went `permission`, `running`,
  `ready`. Resumed with the relay on, into the same session: a dialog showed
  `permission`, an approval `running`, the turn's end `ready`, and Esc
  `interrupted`. `m` squashed it into main.
- Claude Code 2.1.302 (Haiku), relay on: as before, `ready` after a turn
  and `interrupted` after Esc. At first it reported nothing, since the shell
  that started this Emacs exports `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`,
  which turns its reports off; resumed without it, it reported.
- One notification came for each request, each turn that ended and each
  interruption, and none as Codex started.

Two cases found on reading it over had no live run: a dialog shown while
the agent rests, as a Pi extension's at startup or Claude Code's sign-in,
which ended `interrupted` through the relay and now ends `ready`; and a Pi
dialog between runs, which shows `permission`. Review found three more:
Pi's reports reaching the helper out of order across back-to-back dialogs,
which Pi doesn't wait on; a Pi dialog at startup, before its first report;
and a Codex report recorded after a newer hook, as when the registry is
busy. The Python tests replay all of them, with both agents' sequences
above: Codex's through a fixture that reports as it does, Pi's with and
without its newer events, and Pi's extension itself under Node.

Left: with the relay on, a Codex turn that starts before you trust Roost's
hooks shows `ready`, and a Pi dialog names only its title.

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
