# Roost manual

Everything the [README](../README.md) leaves out: installing with other
package managers, fitting Roost to Evil and other setups, a walk through a
day of work, every command and option, and how Roost works.

- [Install](#install), and [fitting your setup](#fitting-your-setup)
- [A day with Roost](#a-day-with-roost)
- [Commands](#commands)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Development](#development)

## Install

Requirements: Emacs 29.1+ and [tmux-control](https://github.com/csheaff/tmux-control)
0.7.0+ (which brings [Eat](https://codeberg.org/akib/emacs-eat)). Each task host needs
Python 3.9+, Git, tmux 3.1+, and an installed, signed-in agent CLI (Codex 0.160.0
or newer). Remote hosts need key- or agent-based SSH; use SSH config aliases for
ports and jump hosts. Roost copies its helper to each host itself.

Emacs 30 (built-in `use-package`):

```elisp
(use-package tmux-control
  :vc (:url "https://github.com/csheaff/tmux-control" :rev :newest))

(use-package roost
  :vc (:url "https://github.com/csheaff/roost" :rev :newest)
  :demand t
  :bind ("C-c r" . roost-dispatch)          ; the menu, from anywhere
  :custom (roost-hosts '(nil "devbox"))     ; nil is this machine
  :config
  (roost-watch-mode 1)                      ; notice waiting agents from startup
  (roost-sidebar-mode 1)                    ; the task list at the left
  (roost-task-panel-mode 1))                ; a task's panel beside its terminal
```

`roost-watch-mode` counts the agents waiting for you in the mode line and
notifies you when one needs you. Without it, that starts only once you open
Roost, so after a restart, agents still at work go unnoticed until then. The
sidebar and the task's panel are optional ([below](#a-day-with-roost)):
without those lines, `b` and `I` show them when you want them.

Emacs 29: `M-x package-vc-install` tmux-control's URL, then Roost's, and
`(setq roost-hosts '(nil "devbox"))` and `(roost-watch-mode 1)`.

straight.el:

```elisp
(use-package tmux-control
  :straight (:host github :repo "csheaff/tmux-control"))
(use-package roost
  :straight (:host github :repo "csheaff/roost" :files ("roost.el" "scripts"))
  :demand t
  :bind ("C-c r" . roost-dispatch)
  :custom (roost-hosts '(nil "devbox"))
  :config (roost-watch-mode 1))
```

Doom Emacs, in `packages.el`:

```elisp
(package! tmux-control :recipe (:host github :repo "csheaff/tmux-control"))
(package! roost :recipe (:host github :repo "csheaff/roost" :files ("roost.el" "scripts")))
```

and in `config.el`: `(setq roost-hosts '(nil "devbox"))` and
`(roost-watch-mode 1)`.

Then run **`M-x roost-doctor`**. It checks Emacs's side and, on each host, SSH,
Python, Git, tmux and each agent CLI's version and sign-in, with a fix for
anything missing. For pull requests it also checks the GitHub CLI and whether
Git on the host can push each project you've used there (a dry run that sends
nothing). `C-u M-x roost-doctor` checks a host before you add it.

Magit is optional (review falls back to Dired).

### Fitting your setup

- **Workspaces.** Each task gets its own window arrangement: a perspective with
  [perspective.el](https://github.com/nex3/perspective-el), otherwise a tab when
  `tab-bar-mode` is on, otherwise none (tasks open in the selected window). Set
  `roost-workspace` to choose.
- **Evil.** Roost's dashboard and panels start in Emacs state so their keys work
  (`roost-evil-state`); `j`/`k` move between tasks. Drafts start in insert
  state. In Magit, Roost's keys work in normal state, with the whole file's
  diff on `g=` (evil-collection uses `=`). tmux-control starts agent
  terminals in insert state, so typing reaches the agent; ESC returns to
  normal state. To stop an agent's turn, which Claude Code does on ESC,
  press `C-c C-c` (Ctrl-C stops it too). With evil-collection, `C-c C-z` in
  normal state switches ESC between the agents and Evil; setting
  `tmux-control-evil-state` to `emacs` sends it to the agents always.
- **Other modal setups** (Meow, xah-fly-keys): put `roost-dashboard-mode`,
  `roost-task-info-mode` and `roost-doctor-mode`, and the drafts
  `roost-compose-mode`, `roost-send-mode` and `roost-pr-mode`, in your insert or
  Emacs-state list so their keys work.
- **Completion.** Prompts use `completing-read`, so Vertico, Ivy, Helm and the
  default UI all work. A new task's project picker offers the projects Roost
  has used, then those `project.el` knows.
- **Remote review.** Magit reaches a remote task through TRAMP, where every Git
  command is a round trip, and a refresh runs a dozen or more. With TRAMP's
  default `scp` method on a host on the same network, Magit took 3.6 s to open
  a task and 1.7 s to refresh or stage a file; with
  [tramp-rpc](https://github.com/ArthurHeymans/emacs-tramp-rpc), which runs
  commands through a small server on the host, 0.4 s. tramp-rpc needs Emacs
  30.1, a newer TRAMP from GNU ELPA and msgpack, and puts its server on each
  host, downloaded from its GitHub releases or built with Cargo. It first
  appeared in 2026. `roost-doctor` names the method each host uses.

## A day with Roost

**Start a task.** `c` opens a draft. The project comes from where you are, or from
projects you've used. Click a field or use its key to change it, write the prompt
(it can span lines), and press `C-c C-c`. Roost creates the branch and worktree,
starts the agent in tmux, and opens its terminal.

**Start from where the work is.** Your task list can stay where it already is:

- Run `M-x roost-new-task` on an Org heading, or on its agenda line. The
  heading and its notes become the prompt, and the heading records the task (a
  `ROOST_TASK` property), so Roost commands run there, such as
  `roost-open-task` or `roost-review`, act on it.
- Select a region first, and the selection becomes the prompt. Code is quoted
  with its file and lines, ready for you to say what to do with it.
- Press `C-c C-t` in the draft to pick one of the project's open GitHub issues.
  Its title and text become the prompt, and the task's pull request will close
  it.

**Let them work.** Start more tasks; each is independent. Roost watches the
agents' own lifecycle hooks and notifies you when one finishes or asks for
permission, with the first line of its reply or what it asks (`Asks to run
make test`), so you can tell from the notification whether it needs you now.
The agent whose terminal you are looking at doesn't notify. The dashboard
shows the same for every agent, and the mode line counts the agents waiting
(`Roost:2`; click it for the next one). `n` jumps to the next agent waiting
for you, permission requests first. Answer it in the terminal, then `n` again.
A link the agent shows there, such as the pull request it opened, opens with
`C-c C-u`, which offers each link on the screen, and with a click when the
agent marks it as a link, as Claude Code does with tmux 3.4 or later (both
need tmux-control later than 0.7.2).
A finished agent you have looked at stops counting, and turns grey, until it
replies again; one that failed or stopped by itself stops counting once you've
seen it. What you've seen is kept on the task's host, for your other machines
and the next session.

**Keep them in view.** `b` in the dashboard, or `M-x roost-sidebar-mode`, keeps a
compact task list at the left of every frame, through perspective and tab
switches and `C-x 1`; add `(roost-sidebar-mode 1)` to your configuration to have
it from the start. `I` docks a panel at the right of an open task's terminal,
kept current as the agent works: what to do next, the task's prompt, and the
files it changed, those not yet committed first. A click or `RET` on a file
opens its diff in Magit, where `;` writes a note for the agent (more under
Review in Magit, below). The terminal shows the agent's replies, so the panel leaves them out
while the terminal is on screen; `i` shows the same panel in the main area,
with the latest reply (a click or `RET` opens a link in it). `?` in the panel
opens the menu of what you can do with the task. Add
`(roost-task-panel-mode 1)` to have the panel from the start. It steps aside
when the terminal would drop below 80 columns, and `q` in it turns it off.

**Check the work yourself.** `t` opens a shell beside the agent, in the same
worktree, and returns to it after. Run the tests, start the app, poke at it.
The agent and the shell are tmux panes, each in a window of its own: `C-x o`
moves between them (so does `C-c C-o`, with tmux-control later than 0.7.2),
`C-c C-t` shows one at a time, and tmux-control's other pane keys work too. `C-c |` splits off another pane,
which starts in the worktree; it closes when its program exits, and every
pane closes when the task stops.

**Review in Magit.** `r` opens Magit on the task's worktree, through TRAMP for
remote tasks. Stage, edit and commit as usual. The status names the task,
keeps the agent's latest reply folded at the top, and lists the commits not
yet in the branch the task merges into (`Unmerged into main`); `RET` on that
heading shows all their changes together, as on Magit's own sections of
unmerged commits.

Staging doubles as approval: stage what you have checked, and whatever the
agent changes after that shows up as unstaged, on its own. To ask for changes,
put point on a line and press `;` to write a note for the agent there (on the
region's lines, or on a file's name for the whole file). Notes show under their
lines, and `@` drafts a prompt holding all of them; sending it clears them. `=`
on a file shows the whole file with its changes marked, and you can still
stage there.

**Catch up and finish.** When other tasks land first, the dashboard shows the
task falling behind (`↓2`). `u` merges the integration branch into the task's
own worktree. If that conflicts, Roost offers to have the task's agent resolve
it, run the tests and commit. Then `m` merges the task into the branch it
started from and removes its worktree, branch and window. For work you don't
want, `x` discards the task, first saying what that loses.

**Or open a pull request.** To finish on GitHub instead, `P` drafts one: the first
line is the title and the rest the body, prefilled from the agent's commit
message. `C-c C-c` pushes the branch and creates it (`C-u C-c C-c` as a draft).
The dashboard then shows `#12` with its checks and review. Send review feedback
to the agent with `e`; when it has committed, `P` pushes the new commits and
opens the pull request. Once it is merged, `x` retires the task and deletes the
branch. Needs `gh` on the task's host, and Git credentials there that can push.

## Commands

`roost-status` opens the dashboard. In it, and in a task's details panel:

| Key | Command | |
| --- | --- | --- |
| `h`, `?` | `roost-dispatch` | A Magit-style menu of every command below, naming the task they act on and what to do next |
| `RET` | `roost-open-task` | Open the task's agent terminal and workspace; for a stopped or crashed agent, offer to resume it |
| `c` | `roost-new-task` | Draft a new task, from the region or Org entry if any (`C-u` forks the current task's commits) |
| `n` | `roost-next-waiting` | Next task waiting for you, permission requests first |
| `t` | `roost-shell` | Shell beside the agent, in the worktree (reused) |
| `f` | `roost-files` | Dired in the worktree |
| `r` | `roost-review` | Magit in the worktree |
| `D` | `roost-diff` | Diff the task's own changes, including uncommitted ones |
| `e` | `roost-send` | Paste a prompt into the agent and press Enter |
| `i` | `roost-task-info` | The task's next step, prompt, latest reply, changes and details |
| `l` | `roost-switch-task` | Choose a task by name, waiting tasks first |
| `/` | `roost-search` | Find messages in your tasks' conversations, retired tasks' too; `RET` opens a live task, `TAB` shows more of a message (its first 1,500 characters) |
| `b` | `roost-sidebar-mode` | Keep the task list at the left of every frame |
| `I` | `roost-task-panel-mode` | Dock the open task's panel beside its terminal |
| `u` | `roost-update` | Merge the integration branch into the task; for uncommitted changes or conflicts, offers to have its agent do it |
| `P` | `roost-pr` | Draft a pull request for the task; if it has one, push new commits and open it (`C-u`: open only) |
| `m` | `roost-merge-retire` | Merge committed work as one commit, then retire the task (a merge commit with `roost-merge-style` set to `merge`) |
| `x` | `roost-retire` | Finish with a task: retire it when its work is merged or it has none, otherwise offer to discard it (`roost-discard`), first saying what would be lost; to lose commits or files you type its name |
| `X` | `roost-forget` | Drop the task from Roost, leaving its worktree and branch as they are |
| `K` | `roost-stop` | Stop the agent's window; keep all work |
| `s` | `roost-resume` | Restart a stopped task in its recorded conversation |
| `g` | `roost-refresh` | Refresh status and Git statistics |

`j`/`k` or `TAB` move between tasks; `mouse-1` opens one and `mouse-3` shows its actions.
Outside the dashboard, commands act on the task of the current terminal,
worktree file, Org entry or perspective, or ask. In an agent's terminal, where
every other key goes to the agent, `C-c ?` opens the menu for its task (while
`roost-watch-mode` is on); so does `C-c ?` in Magit on a task. Bind the menu
globally to reach Roost from anywhere, for example
`(keymap-global-set "C-c r" #'roost-dispatch)`.
Also available: `roost-send-region` (adds the selection, with its file and
lines, to the prompt you are drafting). Roost watches its hosts once you open the dashboard or sidebar or start
a task: every 3 seconds while Emacs is in front, every 15 otherwise.
`roost-watch-mode` turns that off and on.

In Magit on a task's worktree, Roost adds a few keys, and a Roost menu:

| Key | Command | |
| --- | --- | --- |
| `;` | `roost-note` | Write a note for the agent on the line at point, the region's lines, or the file, in a box that opens under it (`C-c C-c` saves, `C-c C-k` cancels); on a noted line, edit its note (saved empty, it is removed) |
| `'` | `roost-goto-note` | Go to one of the task's notes, chosen in the minibuffer |
| `C-c ;` | `roost-note-actions` | Edit a note under the line at point, send it alone to the agent, or discard it |
| `@` | `roost-send` | Draft a prompt to the agent, holding your notes |
| `=` | `roost-diff-whole-file` | Show the whole file with its changes; staging still works (`0` goes back to hunks). A new file opens as it is. With Evil, `g=` |

With the mouse, a `+` shows beside the diff line under the pointer: click it
to write a note on that line, or drag from it along lines for a note on
them. Click a note for a menu that edits it, sends it alone to the agent, or
discards it. The box is a child frame over room left under the line; in a
terminal, it opens in a window below.

`M-x roost-discard-notes` drops a task's notes unsent. In a task's panel, `e`
also drafts a prompt holding them.

In the new task draft: `C-c C-c` creates, `C-c C-k` cancels, and `C-c C-p`,
`C-c C-a`, `C-c C-b` and `C-c C-n` change the project, agent, starting ref and
name. `C-c C-t` starts from a GitHub issue (with `gh` on the project's host). An
empty name is derived from the prompt.

In the pull request draft: `C-c C-c` creates the pull request (`C-u` as a draft)
and `C-c C-k` cancels. A failed creation keeps the draft.

## Configuration

- `roost-hosts`: hosts the dashboard watches (`nil` is local). Hosts and projects
  you create tasks in are remembered in `roost-hosts-file` and `roost-projects-file`;
  `M-x roost-forget-host` stops watching one you no longer use.
- `roost-default-agent`, `roost-agent-commands`: which agent new tasks use, and
  each CLI with extra arguments, such as `("claude" "claude" "--model" "sonnet")`.
  Roost owns worktree, resume and hook flags and rejects conflicting ones.
- `roost-setup-command`: a shell command run once in a new worktree before the
  agent starts, such as `npm ci`. Set it in `.dir-locals.el` per project:
  `((nil . ((roost-setup-command . "npm ci"))))`. Emacs reads a remote
  project's `.dir-locals.el` only with `enable-remote-dir-locals` on. A new
  worktree lacks files Git doesn't track, such as `.env`; the command finds the
  primary checkout in `$ROOST_REPO`: `cp "$ROOST_REPO/.env" . && npm ci`.
- `roost-merge-style`: `squash` (the default) adds one commit holding all of a
  task's work, with a message made from its commits, so each task is one
  change in your history and the merges that kept it up to date (`u`) leave
  no trace there; `merge` brings it in with a merge commit, keeping its
  commits.
- `roost-program-status` (nil, experimental): let the agent say what it is
  doing. Claude Code 2.1.295 and later reports whether it works, waits on you
  or is done (OSC 7501), but only to a terminal that answers its probe, which
  tmux doesn't. With this on, the agent of each new or resumed task runs on a
  terminal of Roost's own, relayed to its tmux pane, that does: an approval, a
  declined request and Esc then show at once.
- `roost-notes-file`: review notes not yet sent, kept across sessions.
- `roost-note-box-lines` (4): how many lines of text the box for writing a
  note shows. Faces `roost-note` and `roost-note-button` color the notes and
  the `+`.
- `roost-magit-status-sections` (t): whether Magit's status of a task's
  worktree names the task and folds in its agent's latest reply.
- `roost-branch-prefix`: topic branches are `PREFIX<name>-<id>`; default `roost/`.
- `roost-state-directory`: where each host keeps task records, the helper and
  worktrees; default `~/.local/share/roost`.
- `roost-socket-name`: the tmux socket (default tmux-control's). Each task has a
  session of its own, named after its project and task.
- `roost-sidebar-width` (30), `roost-task-panel-width` (44): the sidebar and
  the panel docked beside a task's terminal.
- `roost-workspace`, `roost-compact-mode-line`: how tasks get their own windows
  (see above); with perspective.el, task perspectives share one
  `Roost: host/task +N` entry in the perspective bar.
- `roost-mode-line-count`: the waiting count in `global-mode-string`. For a
  mode line of your own, set it to nil and place
  `(:eval (and (fboundp 'roost-mode-line-waiting) (roost-mode-line-waiting)))`
  where you want the count.
- `roost-animations` (nil): on Emacs 32, which draws canvas images, the
  status light of an agent asking you something pulses and one that
  finished, failed or exited since you saw it glows; the rest stay still, and the motion pauses while Emacs
  isn't in front. Elsewhere the lights stay dots.
- Faces: `roost-prose` sets what you and the agents wrote (prompts, replies,
  requests) in `variable-pitch`, keeping tables and code in the fixed-pitch
  font; make it inherit `default` for one font throughout. `roost-field` is
  for actions and files you can click, plain until the mouse is over them;
  make it inherit `link` to underline them. `M-x customize-group RET roost`
  lists the rest.
- `roost-notify`, `roost-notify-function`: notifications use
  [terminal-notifier](https://github.com/julienXX/terminal-notifier) when it is
  installed (`brew install terminal-notifier`), otherwise macOS's own or Emacs's
  `notifications-notify`. With terminal-notifier and an Emacs server
  (`server-start`), clicking one opens its task, and a newer one about the same
  task replaces it.
- `roost-watch-interval` (3 s), `roost-watch-unfocused-interval` (15 s),
  `roost-request-timeout` (60 s), `roost-ssh-share-connections`.

Each poll is one SSH command per host. Roost shares one connection per host
across them (OpenSSH `ControlMaster`, with its socket in the state directory and
closed a minute after the last request), so polls skip the handshake; set
`roost-ssh-share-connections` to nil to leave that to your ssh configuration.
Unreachable hosts are retried with backoff and keep their last known tasks,
marked unreachable.

## How it works

Emacs talks to a small standard-library Python helper on each host, over SSH
with JSON on stdin and stdout. All requests are asynchronous; the dashboard
draws from a local cache. The helper creates worktrees, starts each agent under
a runner in its own tmux window, and records the task.

Status comes from each agent's native lifecycle events: Claude Code hooks passed
with `--settings`, Codex hooks passed per invocation, and a Pi extension. Roost
never changes your global agent settings or answers prompts.

| Status | Meaning |
| --- | --- |
| `running` | The agent is working on a prompt |
| `permission` | The agent asked for permission; answer it in the terminal |
| `ready` | The agent is waiting for your next prompt. Not "reviewed" or "done" |
| `background` | Claude background work or Pi queued messages remain |
| `starting` | Startup prompts may be showing; Codex reports status from its first turn |
| `error` | A turn ended on an API error, such as a usage limit, and the agent waits; `RET` opens it to try again |
| `exited`, `failed` | The agent exited normally, or the CLI failed; `RET` shows its last output |
| `crashed` | The agent's tmux pane disappeared |
| `stopped` | Stopped with `K`; `s` resumes the conversation |

A task's identity is its host and ID. A per-pane ownership tag keeps Roost from
steering or killing an unrelated pane after a tmux restart, and hooks from an
earlier run cannot overwrite a resumed one. Merging needs the task's worktree
clean. With the primary checkout on the task's integration branch, the merge
happens there and needs nothing uncommitted (untracked files stay); with it on
another branch, Git merges into the integration branch without touching your
checkout (Git 2.38 or newer). A conflicting merge leaves nothing changed.
Branches are deleted only if they still point at the commit Roost verified.
Git will not remove a worktree with submodules checked out, since they may
hold the only copy of commits made in them, so Roost refuses to retire one;
once those commits are safe, remove it with `git worktree remove --force` and
retire again.

Things to know:

- Agents report nothing when you answer a permission request, so Roost looks
  for itself. A Claude Code command you approve shows `running` at the next
  poll, once Roost sees it start; declined, or stopped with Esc, the task
  shows `ready`, read from its transcript. Claude Code's other tools, and
  Codex and Pi tasks, may keep showing `permission` until the agent moves on.
  `e` asks before sending to a task in that state. With `roost-program-status`
  on, Claude Code says so itself, at once.
- Roost's task sessions stay out of the corner where tmux-control names other
  sessions with new output, and its terminals don't show that corner: it
  lights up whenever an agent prints anything, and only shows its terminal.
  Roost tells you when an agent needs you, and `n` or a click on `Roost:N`
  switches to the task.
- Claude Code now starts in auto mode for some accounts, approving most
  commands itself, so its tasks rarely ask. To be asked before each command,
  add `"--permission-mode" "manual"` to Claude's entry in `roost-agent-commands`.
- Roost turns on tmux's `extended-keys` on the server it starts agents on, so
  they can tell Shift+Return and Option+Return from Return (a new line in
  Claude's prompt rather than sending it). Programs that do not ask for
  extended keys see no difference. Agents started before it was on need `s`.
- Claude Code can make worktrees of its own (`EnterWorktree`, isolated
  subagents, `/batch`), in the primary checkout's `.claude/worktrees`. In a
  task they start from the task's work, its panel lists them with what they
  hold, each opening in Magit, and the task can't be merged or retired while
  one holds work not on the task's branch.
- Claude and Codex each ask once per repository to trust it; every task worktree
  of that repository is trusted after that.
- Codex asks you to review Roost's observer hooks the first time. The hook
  command stays the same across Roost upgrades. Codex's sandbox keeps a
  worktree's shared `.git` read-only, so it asks before committing.
- Pi is experimental: launch, events and resume were checked, but no full model run.
- A GitHub issue's text goes to the agent as written, and anyone can open an
  issue on a public repository. Read it in the draft before pressing `C-c C-c`.

## Development

`make test compile` runs the ERT suite, the Python lifecycle tests against real
Git and isolated tmux sockets (fixture agents drive the actual hook commands,
without model calls), and a warning-free byte-compile. CI runs it on Emacs 29.1
and 30.1. The tests of Roost in Magit need Magit and its dependencies on the
load path, as `make test TEST_LOAD_PATH="-L …/magit/lisp -L …"`, and Evil
and evil-collection for its Evil keys there; without them they are skipped.

Most ERT tests check one thing someone thought to check. `test/roost-sweep.el`
checks rules instead. It draws the task panel, dashboard, sidebar and search
results for a gallery of task states, presses every button and key in them,
and fails on:

- a view that draws differently the second time, or in other windows: none,
  the one you are in, one beside it (as a panel beside the terminal you type
  in), or two;
- a button or key that ends in a Lisp error, rather than doing its job, asking,
  or saying why it can't (`user-error`);
- a button or key that changes only the view, when a redraw undoes the change
  or nothing changes it back;
- a key the task panel tells you to press that isn't bound there, or whose
  command doesn't apply to the task.

Hosts, processes, terminals, Magit, the menu and the browser are stubbed, and
every question is answered with `C-g`. A new button or key is covered as it
is. A new kind of task needs a state in `roost-sweep--gallery`, and a new view
an entry in `roost-sweep--views`.

Claude Code updates itself often, and Roost relies on what it reports and
does. `make contract` scans the installed Claude Code for the hook events,
notification types and payload fields Roost reads, and names any it has not
seen; `make contract-live` also takes a real session (a few short Haiku turns,
about three minutes) through each status Roost derives: a reply, a permission
request approved and declined, Esc, a minute idle and `/clear`. Run them after
Claude Code updates.

See [validation](validation.md) for the live runs with Claude Code and Codex on
local and remote hosts, [the demo notes](demo.md) for how the screenshots
were made, and [MELPA](melpa.md) for the package recipes.
