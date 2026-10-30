# Roost manual

Everything the [README](../README.md) leaves out: installing with other
package managers, fitting Roost to Evil and other setups, a walk through a
day of work, every command and option, and how Roost works.

- [Install](#install), and [fitting your setup](#fitting-your-setup)
- [A day with Roost](#a-day-with-roost), and [what a task says](#what-a-task-says)
- [Commands](#commands)
- [Configuration](#configuration), and [where a task's skills come from](#where-a-tasks-skills-come-from)
- [How it works](#how-it-works), and [security](#security)
- [Development](#development)

## Install

Requirements: Emacs 29.1+ and [tmux-control](https://github.com/csheaff/tmux-control)
0.8.2+ (which brings [Eat](https://codeberg.org/akib/emacs-eat)). Each task host needs
Python 3.9+, Git, tmux 3.1+, and an installed, signed-in agent CLI (Claude Code
2.1.78 or newer, Codex 0.160.0 or newer). Remote hosts need key- or agent-based
SSH; use SSH config aliases for ports and jump hosts. Roost copies its helper to each host itself.

Emacs 30 (built-in `use-package`):

```elisp
(use-package tmux-control
  :vc (:url "https://github.com/csheaff/tmux-control" :rev :newest))

(use-package roost
  :vc (:url "https://github.com/csheaff/roost" :rev :newest)
  :demand t
  :bind ("C-c r" . roost-dispatch)          ; the menu, from anywhere
  ;; :custom (roost-hosts '(nil "devbox"))  ; SSH hosts too; nil is this one
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
`(roost-watch-mode 1)`; for SSH hosts, `(setq roost-hosts '(nil "devbox"))`.

straight.el:

```elisp
(use-package tmux-control
  :straight (:host github :repo "csheaff/tmux-control"))
(use-package roost
  :straight (:host github :repo "csheaff/roost" :files ("roost.el" "scripts"))
  :demand t
  :bind ("C-c r" . roost-dispatch)
  ;; :custom (roost-hosts '(nil "devbox"))
  :config (roost-watch-mode 1))
```

Doom Emacs, in `packages.el`:

```elisp
(package! tmux-control :recipe (:host github :repo "csheaff/tmux-control"))
(package! roost :recipe (:host github :repo "csheaff/roost" :files ("roost.el" "scripts")))
```

and in `config.el`: `(roost-watch-mode 1)`, and for SSH hosts
`(setq roost-hosts '(nil "devbox"))`.

Then run **`M-x roost-doctor`**. It checks Emacs's side and, on each host, SSH,
Python, Git, tmux and each agent CLI's version and sign-in, with a fix for
anything missing. For pull requests it also checks the GitHub CLI and whether
Git on the host can push each project you've used there (a dry run that sends
nothing). `C-u M-x roost-doctor` checks a host before you add it.

Magit is optional (review falls back to Dired).

### Fitting your setup

- **Workspaces.** Each task gets its own window arrangement: a perspective with
  [perspective.el](https://github.com/nex3/perspective-el), otherwise a tab when
  `tab-bar-mode` is on, otherwise none: a frame shows one task, whose
  terminal takes the place of another's. `r`, `f` or `D` on another task's
  row opens its terminal first, then its Magit, files or diff. Retiring,
  merging, discarding or forgetting a task closes its workspace; files you
  opened in it stay open. Set `roost-workspace` to choose. A task's
  perspective lists the tmux windows of its session you have visited; to
  list every one from the start, such as a shell you left open, set
  `tmux-control-window-buffers` to `all` (tmux-control 0.8.3), and to tell
  them apart by name, `tmux-control-window-buffer-names` to `tab`.
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
  `roost-task-info-mode`, `roost-doctor-mode` and `roost-workload-mode`, and the drafts
  `roost-compose-mode`, `roost-send-mode` and `roost-pr-mode`, in your insert or
  Emacs-state list so their keys work.
- **Completion.** Prompts use `completing-read`, so Vertico, Ivy, Helm and the
  default UI all work. A new task's project picker offers the projects Roost
  has used, then those `project.el` knows. With Orderless, `M-x` with much of
  a long name typed, such as `roost-new-task-from-region`, is followed by a
  second or more in which Emacs works out a shorter name to suggest ("You can
  run the command … with M-x -task-from-r"), and terminals don't update until
  you press a key; `(setq extended-command-suggest-shorter nil)` turns that
  off.
- **Remote review.** Use
  [tramp-rpc](https://github.com/ArthurHeymans/emacs-tramp-rpc) for remote
  hosts if you can. Magit reaches a remote task through TRAMP, where every Git
  command is a round trip, and a refresh runs a dozen or more. With TRAMP's
  default `scp` method on a host on the same network, Magit took 3.6 s to open
  a task and 1.7 s to refresh or stage a file; with tramp-rpc, which runs
  commands through a small server on the host, 0.4 s. tramp-rpc needs Emacs
  30.1, TRAMP 2.8.1.4 or later from GNU ELPA and msgpack, and a host running
  Linux or macOS on x86_64 or aarch64, where it puts its server, downloaded
  from its GitHub releases or built with Cargo. It first appeared in 2026.
  With Emacs 30:

  ```elisp
  (use-package tramp-rpc
    :after tramp
    ;; Its latest release: the server it puts on each host comes from one,
    ;; and a newer commit can speak a newer protocol than that server.
    :vc (:url "https://github.com/ArthurHeymans/emacs-tramp-rpc"
         :rev :last-release :lisp-dir "lisp")
    :config
    ;; Roost's paths to remote tasks use TRAMP's default method.
    (setq tramp-default-method "rpc"))
  ```

  If your SSH configuration forwards ports for a host, add
  `"-o" "ClearAllForwardings=yes"` to `tramp-rpc-ssh-args`: ssh's messages
  about forwarding mix into tramp-rpc's replies. `roost-doctor` names the
  method each host uses.

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
  with its file and lines, ready for you to say what to do with it: its lines
  in the whole file, though you have narrowed to it, and from an Org source
  block you are editing with `C-c '`, the Org file and its lines.
- On an error in a compilation buffer, or a match in a grep buffer, that line
  becomes the prompt, with its file and line.
- With [Embark](https://github.com/oantolin/embark), act on a region, a file,
  a URL or a Flymake diagnostic to start a task about it. Roost leaves
  Embark's keys alone; to put its actions on `T`:

  ```elisp
  (with-eval-after-load 'embark
    (keymap-set embark-region-map "T" #'roost-new-task-from-region)
    (keymap-set embark-file-map "T" #'roost-new-task-from-file)
    (keymap-set embark-url-map "T" #'roost-new-task-from-url)
    (keymap-set embark-flymake-map "T" #'roost-new-task-from-diagnostic))
  ```

  A file is named from the top of its checkout, and the task goes to that
  project. A diagnostic is quoted with its file, line and message, then the
  code it is on. The same commands work with `M-x`.
- Press `C-c C-t` in the draft to pick one of the project's open GitHub issues.
  Its title and text become the prompt, and the task's pull request will close
  it.

A draft that quotes a file, as one from code, a file, a diagnostic, an error
or a match does, names the project's tasks that already change it, below its
fields: `ledger-totals already changes report.py`, in one line however many
there are: three by name, then how many more, named when you hover over
the count. Two tasks that change one file can conflict when the second
merges. Starting this one anyway, waiting,
or giving the work to that task instead is up to you: a click on its name
opens it, and `C-c C-c` starts the new one as usual. Roost goes by the
changed files the task panel lists, measured again after each agent's edits
while it watches, and the line keeps up with them. A file you mention
yourself doesn't count, nor does a quote you delete.

**Let them work.** Start more tasks; each is independent. Roost watches the
agents' own lifecycle hooks and notifies you when one needs you, titled with
the task and its status. A permission request notifies at once and alone,
with what it asks (`ledger — permission`, `Asks to run make test`), since its
agent can do nothing until you answer. The rest, a finished turn, a failure,
or a pull request or conflicts that wait on you, gather across tasks for up
to a minute into one notification: it names the most urgent, as `n` orders
them, with the first line of its reply or why it waits, and counts the
others (`+2 more: 1 ready, 1 failed`). One you see in that minute, or whose
task moves on, drops out. The agent whose terminal you are looking at
doesn't notify. The dashboard
shows the same for every agent, and the mode line counts the agents waiting
(`● Roost:2`, the dot in the colour of the most pressing; click it for the
next one). `n` jumps to the next agent waiting
for you, permission requests first, and the echo area says which task it
opened, why that one waits and how many more do, as in `permission ·
ledger: Asks to run make test; 2 more waiting`; in a narrow frame, why it
waits is cut short first. Answer it in the terminal, then `n` again. Once
none waits, `n` says so and offers the way back to where you pressed the
first `n`: press it again to go there. With workspaces that is the
perspective or tab you were in; without, the frame's windows as they were.
A link the agent shows there, such as the pull request it opened, opens with
`C-c C-u`, which offers each link on the screen, and with a click when the
agent marks it as a link, as Claude Code does with tmux 3.4 or later.
A finished agent whose reply you have seen stops counting, and turns grey,
until it replies again; one that failed or stopped by itself stops counting
once you've seen it. What you've seen is kept on the task's host, for your
other machines and the next session.

**Keep them in view.** `b` in the dashboard, or `M-x roost-sidebar-mode`, keeps a
compact task list at the left of every frame, through perspective and tab
switches and `C-x 1`; add `(roost-sidebar-mode 1)` to your configuration to have
it from the start. Each task there is its name and, at the right, its status:
in its colour when the task waits for you, such as `permission` or a `ready`
you haven't seen, plain when it is `merged`, dim when the agent is only
working or stopped, and none once you've seen an agent that waits for nothing; then, dim, what changed
since you last looked at it, if anything (below), where the whole name fits
beside it. A click opens the task,
quitting any question you left open in the minibuffer, which would hold it back,
and closing a menu left open. `I` docks a panel at the right of an open task's terminal,
kept current as the agent works: what to do next, the start of the task's
prompt, three lines there, the files it changed, those not yet committed
first, and what a merge would rest on (below). Once you have sent the agent more, your latest prompt shows
under the task's, a reminder of where you left off that the terminal may
have scrolled away. A click or `RET` on a file
opens its diff in Magit, where `;` writes a note for the agent (more under
Review in Magit, below). The terminal shows the agent's replies, so the panel leaves them out
while the terminal is on screen; `i` shows the same panel in the main area,
with the latest reply after the changes (a click or `RET` opens a link in it). `?` in the panel
opens the menu of what you can do with the task. Add
`(roost-task-panel-mode 1)` to have the panel from the start. It steps aside
when the terminal would drop below 80 columns, and `q` in it turns it off.

**Check the work yourself.** `t` opens a shell beside the agent, in the same
worktree, and returns to it after. Run the tests, start the app, poke at it.
The agent and the shell are tmux panes, each in a window of its own: `C-x o`
moves between them (so does `C-c C-o`),
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
task falling behind (`↓2`). If merging the task's commits would then
conflict, a notification says so, and the task panel and menu say so before
you press `m`, as in
"Conflicts with main in ledger.py: `u` merges main into it", and once
you've seen what its agent last said, the task says `conflicts` and counts
as waiting: `n` visits it. Roost checks whenever the task's branch or the
integration branch moves, with `git merge-tree` on the task's host (Git
2.38 or newer; older Git doesn't check). For a task with an open pull
request, GitHub says whether it conflicts instead. The panel also names
other tasks of the project that change the same files, committed or not,
in one line ("ledger totals and report chart also change report.py"),
which may conflict once one of them merges. `u` merges the integration branch into the task's
own worktree. If that conflicts, Roost offers to have the task's agent resolve
it, run the tests and commit. With Git's `rerere.autoUpdate`, Git may resolve
the conflicts as you resolved them before and stage them; the merge then stays
under way, and Roost offers to have the agent check those resolutions and
commit it. Then `m` merges the task into its integration
branch and removes its worktree, branch and window. For work you don't
want, `x` discards the task, first saying what that loses.

**Or open a pull request.** To finish on GitHub instead, `P` drafts one: the first
line is the title and the rest the body, prefilled from the agent's commit
message. `C-c C-c` pushes the branch and creates it (`C-u C-c C-c` as a draft).
The dashboard then shows `#12` with its checks and review, as it does for a pull
request the agent opened itself from the task's branch. Send review feedback
to the agent with `e`; when it has committed, `P` pushes the new commits and
opens the pull request. Once it is merged, `x` retires the task and deletes the
branch. Needs `gh` on the task's host, and Git credentials there that can push.

What each task's row, panel and notification say is in
[What a task says](#what-a-task-says).

## What a task says

The sidebar and the dashboard give each task a word after its name. The
table's second column says when a task waits for you: those are the tasks
`n` visits, the mode line counts and a notification announces. In the
sidebar, their word is in its colour, and an agent you've seen that waits
for nothing has none; the dashboard shows every task's word, and counts
them by those words at its top, what can't go on without you first. In
the dashboard and the task panel, the dot before a task's word is dim
when the task waits for nothing.

| Word | Waits for you | What it means |
| --- | --- | --- |
| `permission` | Yes, before the rest | The agent asks something, or a dialog of its waits; answer it in its terminal |
| `starting` | Once it seems held at a startup prompt, such as folder trust | The agent is starting. Without `roost-program-status`, Codex reports its status only from its first turn |
| `ready` | Until you've seen its reply | Its turn is over and it waits for your next prompt. Not "reviewed" or "done" |
| `interrupted` | Until you've seen it | You stopped its turn, with Esc or by declining a request |
| `error` | Until you've seen it | A turn ended on an API error, such as a usage limit; `RET` opens it to try again |
| `failed`, `exited` | Until you've seen it | The agent's CLI failed, or it exited; `RET` shows its last output |
| `crashed` | Until you've seen it | Its tmux pane went, as when the host or its tmux server restarted; `RET` or `s` resumes its conversation, and asks once to resume every other agent that crashed on that host. Those stopped, exited or failed stay as they are |
| `conflicts` | Once you've seen its reply | Merging its commits into the branch it merges into would conflict; `u` brings that branch in |
| `to merge` | Once you've seen its reply | Its pull request passed its checks and review, and GitHub finds no conflicts; `P` opens it |
| `ci failed` | Once you've seen its reply | A check of its pull request failed |
| `comments` | Once you've seen its reply | A review thread on its pull request is unresolved, Copilot's too |
| `running` | No | The agent works on a prompt |
| `background` | No | Claude's background work, or Pi's queued messages, remain |
| `stopped` | No | Stopped with `K`; `s` resumes its conversation |
| `merged` | No | Its work is merged, on GitHub or into its branch; `x` retires it |
| `offline` | No | Its host doesn't answer; the row is as it was last known |
| `seen` | No | You've seen an agent that waits for nothing, or it has done nothing since it started or you resumed it. The sidebar leaves it without a word; its panel, the menu and search say `seen` too |

A task that waits for nothing may say, dim, what changed since you last
looked at it, `3 files changed since you looked`, or with Magit,
`not looked at`, where its whole name leaves room. A dim `±` after a name
marks a large change. The sections below say more of each, and of what
the task panel shows.

### How large a change is

The task panel says how large a task's
changes are, counted from where its work leaves the branch it merges into,
with uncommitted work and new files included: `14 files +540 −88`, then the
top-level directories they are in, `In docs/, src/, test/ and the top
level`. A task whose changes reach 400 lines (added and removed together),
10 files or 3 top-level directories gets a dim `±` after its name in the
sidebar and dashboard, so you can tell an hour of reading from ten minutes
before you open Magit; hover over the row for its numbers. The mark only
gives the size: the task doesn't count as waiting for it. Studies of code
review find that reviewers catch less, and take longer, as changes grow and
spread; they support marking large changes more than these exact numbers,
which you can change with `roost-large-change`.

### What a merge rests on

Under the files, the task panel lists
what you can judge a change by, the easiest to check first. `Checks` names
each check of the task's pull request that failed or is still pending, as
GitHub last said, and counts those that passed. Without a pull request, or
for one with no checks, it says `No CI results`, which looks unlike checks
that passed; for a pull request without the task's newest commits, a commit
amended since, or its uncommitted changes, it says the checks didn't run on
them. `Open review threads` lists the pull request's unresolved threads,
Copilot's too, each with its file and line, who started it and how. `RET` on
one visits that line in the task's worktree, in another window, as the pull
request has it; for a thread on a deleted line, one the agent has changed
since, or one on the whole file, it shows the file's changes. The agent's
latest reply comes last, marked as its own account: `No CI results` beside a
reply that says the tests pass means only the agent says so, perhaps from a
run in its terminal. Beside the terminal, where the reply is the terminal's,
a task without a pull request leaves `Checks` out. Roost judges neither, and
gives no score or verdict on whether to merge.

### Since you last looked

Opening a task with `r`, or its whole diff with
`D` when no new file is left out of it, or sending its agent your notes with
`@`, records where its work stands as where you last looked at it,
uncommitted work too. `v` records a look too, and opens nothing: for a task
you judged by its panel, or whose diff you read in its agent's terminal.
Once you've seen its agent's reply, the
sidebar and dashboard say, dim, what changed since (`3 files changed since
you looked`), and its panel says when you looked: `r` shows the changes, and
`v` marks it looked at. It
doesn't count as waiting. Roost compares content, so commits the agent
makes of what you saw, amends or rebases don't count, nor do files only an
update from the integration branch brought in; anything else changed does,
whatever prompted it. With Magit, a task you never looked at says `not
looked at`. In Magit, a section beside `Unmerged into main` lists the files
that changed between your last two looks; `RET` on its heading shows their
changes together, and on a file, its own, where `;` writes notes as in any
diff. `m` and `P` say so too before you merge or push.

### A pull request that waits on you

Roost notifies you when a task's pull
request comes to wait on you, and once you've seen what its agent last said,
the task counts as waiting: `n` visits it, the mode line counts it, and the
sidebar and dashboard say why:

- `to merge`: every check passed, no review is asked for or unresolved, and
  GitHub finds no conflicts. `P` opens it.
- `ci failed`: a check failed.
- `comments`: a review thread is unresolved, Copilot's too, even one the agent
  answered and left open.

A failed check or a new thread waits two minutes first: an agent that watches
its own pull request takes it up by then, and shows as working. The status
lasts until the pull request changes or the agent starts again, whether or not
you've seen it. Before that, the task panel says what the pull request waits
for, such as its checks or Copilot's review. Roost only says when it's your
turn: `e` tells the agent what to fix. It goes by what GitHub said after the
agent's last push, while the branch has no commits the pull request lacks and
nothing is left uncommitted or in the agent's own worktrees.

### Work that is merged

A task whose work is merged, on GitHub or into the branch it
merges into, says `merged` in the dashboard and sidebar once you've seen its
agent's last reply, so you can tell which tasks to retire without opening them.
Nothing is lost by retiring it with `x`: nothing is left uncommitted, and its
commits are all in what was merged. Commits made after its pull request merged
keep it from saying so.

### A worktree on another branch

You or a task's agent may make a branch in its worktree and work there, as
with `git switch -c feat`. `m`, `P`, `u` and retiring act on the task's own
branch, so its host refuses them until the worktree is back on it. The task
panel's next step says so, with how to finish the task, and beside the
task's changes, which are then that branch's, as in Magit and the diff, a
line in the colour of what needs you says whose they are: "These are feat's
changes, not roost/fix-parser's". While the next step is about something
else, as for a stopped agent, that line says which branch the worktree is
on and how to finish the task itself. Its details say so too, the dashboard's changes start
with `on feat` (`detached` for a detached HEAD), and the task doesn't say
`merged` or `conflicts`, which go by its own branch. To finish it:

- To merge the work with `m` or `P`, check out the task's branch in the
  worktree and merge `feat` into it.
- `x` discards the task: its worktree, its own branch and its window go,
  and `feat` keeps its commits. It first says what that loses, as files not
  committed, or commits made on a detached HEAD.

Roost finds a pull request opened from the task's branch, not from `feat`.

### How many agents you keep up with

`w`, or `M-x roost-workload`, shows, for
today and each day of the past week, the most agents that worked at once, how
long they worked, and how long they waited on you: asked you something, ended
a turn or failed before you saw them, or had a pull request or conflict for you,
added up across agents, with the longest single wait. The last column is that
waiting for each hour of work. A day with more agents at once should show more
work; past what you can supervise, it shows more waiting for each hour of work
instead, as agents queue for you. Thirty minutes with no change on any host,
as overnight, count as time away and are left out of the waiting. `g` asks
the hosts again. Each host's helper keeps the history, 30 days of it, under
`history` in its state directory; an agent started before you upgraded is
counted once you stop and resume it (`K`, then `s`).

## Commands

`roost-dashboard` opens the dashboard. In it, and in a task's details panel:

| Key | Command | |
| --- | --- | --- |
| `h`, `?` | `roost-dispatch` | A Magit-style menu of every command below, naming the task they act on and what to do next |
| `RET` | `roost-open-task` | Open the task's agent terminal and workspace; for a stopped or crashed agent, offer to resume it, in the same question as the others that crashed on its host |
| `c` | `roost-new-task` | Draft a new task, from the region or Org entry if any (`C-u` forks the current task's commits) |
| `n` | `roost-next-waiting` | Next task waiting for you, permission requests first, saying why it waits; once none does, again goes back to where you started |
| `t` | `roost-shell` | Shell beside the agent, in the worktree (reused) |
| `f` | `roost-files` | Dired in the worktree |
| `r` | `roost-review` | Magit in the worktree, showing what changed since you last looked |
| `D` | `roost-diff` | Diff the task's own changes, including uncommitted ones; with no new file left out, that counts as looking at it |
| `v` | `roost-mark-looked` | Record that you've looked at the task as it stands now, opening nothing, so what changed since you looked starts from here |
| `e` | `roost-send` | Paste a prompt into the agent and press Enter |
| `i` | `roost-task-info` | The task's next step, prompt, your latest prompt, changes, checks, open review threads, the agent's latest reply and details |
| `R` | `roost-rename` | Rename the task, in Roost, its tab or perspective, and its agent's tmux window; its branch and worktree keep the name it started with |
| `l` | `roost-switch-task` | Choose a task by name, waiting tasks first |
| `/` | `roost-search` | Find messages in your tasks' conversations, retired tasks' too; `RET` opens a live task, `TAB` shows more of a message (its first 1,500 characters) |
| `b` | `roost-sidebar-mode` | Keep the task list at the left of every frame |
| `I` | `roost-task-panel-mode` | Dock the open task's panel beside its terminal |
| `u` | `roost-update` | Bring the task up to date: merge the branch it merges into, such as `main`, into it; for uncommitted changes or conflicts, offers to have its agent do it |
| `P` | `roost-pr` | Draft a pull request for the task; if it has one, push new commits and open it (`C-u`: open only) |
| `m` | `roost-merge-retire` | Merge committed work as one commit, then retire the task (a merge commit with `roost-merge-style` set to `merge`) |
| `x` | `roost-retire` | Finish with a task: retire it when its work is merged or it has none, otherwise offer to discard it (`roost-discard`), first saying what would be lost; to lose commits or files you type its name |
| `X` | `roost-forget` | Drop the task from Roost, leaving its worktree and branch as they are |
| `K` | `roost-stop` | Stop the agent's window; keep all work |
| `s` | `roost-resume` | Restart a stopped or crashed task in its recorded conversation; when other agents crashed on its host too, as after it restarted, ask whether to resume those as well |
| `w` | `roost-workload` | How long agents worked and waited on you, each day of the past week ([below](#how-many-agents-you-keep-up-with)) |
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
Every two minutes, and whenever you open the dashboard or refresh it with `g`, it also
asks GitHub about the pull requests of tasks whose branch was pushed, with one
`gh api graphql` query per repository for review threads and where they are.
`roost-watch-mode` turns that off and on.

In Magit on a task's worktree, Roost adds a few keys, and a Roost menu:

| Key | Command | |
| --- | --- | --- |
| `;` | `roost-note` | Write a note for the agent on the line at point, the region's lines, or the file, in a box that opens under it (`C-c C-c` saves, `C-c C-k` cancels); on a noted line, edit its note (saved empty, it is removed) |
| `'` | `roost-goto-note` | Go to one of the task's notes, chosen in the minibuffer |
| `C-c ;` | `roost-note-actions` | Edit a note under the line at point, send it alone to the agent, or discard it |
| `@` | `roost-send` | Draft a prompt to the agent, holding your notes; sending them counts as looking |
| `=` | `roost-diff-whole-file` | Show the whole file with its changes; staging still works (`0` goes back to hunks). A new file opens as it is. With Evil, `g=` |

With the mouse, a `+` shows beside the diff line under the pointer: click it
to write a note on that line, or drag from it along lines for a note on
them. Click a note for a menu that edits it, sends it alone to the agent, or
discards it. The box is a child frame over room left under the line; in a
terminal, it opens in a window below.

`M-x roost-discard-notes` drops a task's notes unsent. In a task's panel, `e`
also drafts a prompt holding them.

In a prompt draft (`e` or `@`): `C-c C-c` sends, `C-c C-k` cancels, `C-c C-a`
attaches a file from this machine and `C-c C-v` the image on the clipboard (as does
`M-x yank-media`, where Emacs reads images from the clipboard). Roost copies
an attachment to the task's host in the background, under `attachments` in its
state directory there, where the agent can read it. Meanwhile the draft shows
`[Copying shot.png…]`, and you can go on writing; the path takes its place, or
a note that it failed, which you delete before sending. `C-c C-c` waits until
none is left copying. Agents read a task's attachments without asking: Roost
starts Claude with `--add-dir` for them, and its OpenCode plugin adds a rule
allowing them to each agent, after OpenCode has read your config, so your
permission settings stand for every other folder. The copies go when the task does. For the folder of a [Scrawl](https://scrawl.kitlangton.com)
capture (`M-n` at the prompt gives the newest), Roost copies all of it but its
video and audio, and adds its summary. `M-x roost-attach` drafts a
prompt with a file attached, or with the files marked in Dired.

Without workspaces, a prompt or pull request draft you leave for another
task's terminal waits off screen, as you left it, and comes back beside its
task's terminal when you open that task again.

In the new task draft: `C-c C-c` creates, `C-c C-k` cancels, and `C-c C-p`,
`C-c C-a`, `C-c C-b` and `C-c C-n` change the project, agent, starting ref and
name. `C-c C-t` starts from a GitHub issue (with `gh` on the project's host). An
empty name is derived from the prompt; `R` renames the task later.

A task's integration branch is the one `m` merges it into, `u` updates it
from, `P` opens its pull request against, and `↑`/`↓` count from. It is the
branch the task starts from, and the draft says so next to the starting ref
("merges into release"). A remote-tracking branch, such as `origin/main`,
gives the local branch of its name, which Roost makes to track it if there
isn't one, as `git switch` would. A task's branch, as when you fork one with
`C-u c`, gives that task's integration branch. With no starting ref, or a
tag or commit, it is the branch the primary checkout has checked out.

In the pull request draft: `C-c C-c` creates the pull request (`C-u` as a draft)
and `C-c C-k` cancels. A failed creation keeps the draft.

## Configuration

- `roost-hosts`: hosts the dashboard watches (`nil` is local). Hosts and projects
  you create tasks in are remembered in `roost-hosts-file` and `roost-projects-file`;
  `M-x roost-forget-host` stops watching one you no longer use, and closes
  its tasks' terminals and panels; their agents keep running.
- `roost-default-agent`, `roost-agent-commands`: which agent new tasks use, and
  each CLI with extra arguments, such as `("claude" "claude" "--model" "sonnet")`.
  Roost owns worktree, resume and hook flags and rejects conflicting ones.
- `.worktreeinclude`, a file in the project's primary checkout: the files Git
  ignores that a new worktree should have, such as `.env`, which a worktree
  otherwise lacks. It takes `.gitignore`'s patterns, and Roost copies the
  files that match one and that Git ignores, from the primary checkout into
  each new task's worktree, as Claude Code and Conductor do, so one file
  serves all three. A file Git tracks, or one it shows as untracked, isn't
  copied, so a new skill you haven't committed doesn't reach a task
  ([skills](#where-a-tasks-skills-come-from)). Git must ignore a copied
  file on the task's branch too, or an agent's `git add .` could commit
  it: when a task starts from a branch whose
  `.gitignore` doesn't have `.env`, or before you commit the line that adds
  it, the task stops and says so. Git reads the patterns as it reads a
  `.gitignore`, so one without a slash matches at any depth: `.env` also
  copies a `.env` inside an ignored `node_modules/`, which Claude Code
  skips. To copy only the top one, write `/.env`, or leave the directory
  out with `!node_modules/**`. Links are copied as links, and files the
  worktree has already are left as checked out. The copy runs in the
  task's terminal, before the setup command. If a file can't be copied,
  the task stops before its agent starts and says which; `s` copies what's
  still missing and starts it. A directory you list is copied file by file
  for each task: `node_modules` takes that time and space every time,
  where `npm ci` as the setup command may take less.
- `roost-setup-command`: a shell command run once in a new worktree before the
  agent starts, such as `npm ci`. Set it in `.dir-locals.el` per project:
  `((nil . ((roost-setup-command . "npm ci"))))`. Emacs reads a remote
  project's `.dir-locals.el` only with `enable-remote-dir-locals` on. It runs
  once Roost has copied what `.worktreeinclude` lists, and finds the primary
  checkout in `$ROOST_REPO`, for anything else it needs from there.
- `roost-teardown-command`: a shell command run in a task's worktree just before
  Roost removes it, when you merge, retire or discard the task, set the same
  way. It cleans up what a tool keeps for the worktree elsewhere, such as
  Bazel's output base and server:
  `ob=$(bazel info output_base) && bazel shutdown && chmod -R u+w "$ob" && rm -rf "$ob"`.
  It runs on the task's host with the primary checkout in `$ROOST_REPO`, and
  is stopped after two minutes; to take longer, it can leave work outside the
  worktree running in the background (`rm -rf "$ob" &`). If it fails, Roost
  warns, with what it printed, and removes the worktree anyway. A file it
  leaves in the worktree keeps the task from retiring, as yours would.
  Emacs counts a command from `.dir-locals.el` as risky, so it asks each time
  Roost reads that file, as you create or finish a task. To trust one, add it to `safe-local-variable-values`, such as
  `(add-to-list 'safe-local-variable-values '(roost-teardown-command . "make clean"))`,
  or, from Emacs 30, the project to `safe-local-variable-directories`.
- `roost-merge-style`: `squash` (the default) adds one commit holding all of a
  task's work, with a message made from its commits, so each task is one
  change in your history and the merges that kept it up to date (`u`) leave
  no trace there; `merge` brings it in with a merge commit, keeping its
  commits.
- `roost-program-status` (nil, experimental): let the agent say what it is
  doing. Claude Code 2.1.295, Codex 0.163.0 and Pi 1.1.0 and later report
  whether they work or wait on you (OSC 7501), which tmux drops; Claude Code
  and Pi report only to a terminal that answers their probe, which tmux
  doesn't. With this on, the agent of each new or resumed task runs on a
  terminal of Roost's own, relayed to its tmux pane, that does: an approval
  then shows at once, and for Claude Code a declined request and Esc too. A
  Codex task is `ready` once you have answered its startup questions, rather
  than at its first turn.
- `roost-large-change` (`(:lines 400 :files 10 :directories 3)`): when a
  task's row gets its `±`. Leave one out to mark by the others, as
  `(:lines 400)`; nil marks none.
- `roost-notes-file`: review notes not yet sent, kept across sessions.
  Faces `roost-note` and `roost-note-button` color the notes and the `+`.
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
  `Roost: host/task +N` entry in the perspective bar, and a click on it shows
  the tasks in a menu. In a workspace that is no task's, such as the one a
  frame made with `C-x 5 2` starts in, the panel and the sidebar follow the
  task whose terminal it shows.
- `roost-mode-line-count`: the waiting count in `global-mode-string`. For a
  mode line of your own, set it to nil and place
  `(:eval (and (fboundp 'roost-mode-line-waiting) (roost-mode-line-waiting)))`
  where you want the count.
- `roost-animations` (nil): on Emacs 32, which draws canvas images, the
  status light of an agent asking you something fades out and back in,
  in the dashboard, the task panel and the mode line. The rest stay
  still, in colour while they wait for you, as moving lights cost Emacs a
  few percent of a core while they move. The motion pauses while Emacs
  isn't in front. Elsewhere the lights stay dots.
- Faces: `roost-prose` sets what you and the agents wrote (prompts, replies,
  requests) in `variable-pitch`, keeping tables and code in the fixed-pitch
  font; make it inherit `default` for one font throughout. `roost-field` is
  for actions and files you can click, plain until the mouse is over them;
  make it inherit `link` to underline them. `roost-current` is the band
  across the sidebar's row for the task you are working on. Colour is kept
  for what needs you, so line counts (`roost-diff-added`,
  `roost-diff-removed`), an open or merged pull request and passed checks
  are plain; make the line counts inherit `success` and `error` to colour
  them as Magit does.
  `M-x customize-group RET roost` lists the rest.
- `roost-notify`, `roost-notify-function`: notifications use
  [terminal-notifier](https://github.com/julienXX/terminal-notifier) when it is
  installed (`brew install terminal-notifier`), otherwise macOS's own or Emacs's
  `notifications-notify`. With terminal-notifier and an Emacs server
  (`server-start`), clicking one opens its task, the most urgent of those it
  counts, quitting a question you left open in the minibuffer as a click in
  the sidebar does. A newer permission request from the same task replaces
  one, and a newer gathered notification the one before. A
  `roost-notify-function` of yours is called with each one's title and body;
  a gathered one's body counts the others on a second line.
- `roost-task-status-functions`, `roost-task-merged-functions`: your own
  functions to run when a task's status changes, or once its work is merged.
  Each status function is called with the task, its status before and its
  status now, as the host records them: `starting`, `running`, `ready` (its
  turn is over), `permission`, `failed`, `crashed`, `exited` or `stopped`,
  and, as Roost lets the task go, `retired`, `discarded` or `forgotten`.
  They run for changes this Emacs sees, not when Roost first sees a task.
  Each merged function is called with the task and the branch its work went
  into, when `m` merges it or when Roost sees GitHub merge its pull request.
  Roost asks GitHub every two minutes, about the branch's latest commit, so
  a pull request merged and followed by new commits before then goes
  unreported.
  The task is an alist; `alist-get` reads its `name`, `id`, `host` (nil on
  this machine), `agent`, `branch`, `worktree` and `integrationBranch`. A
  function that fails is reported in `*Messages*`, and the rest still run.
  For example, to log each time an agent asks for permission:

  ```elisp
  (add-hook 'roost-task-status-functions
            (lambda (task _previous status)
              (when (equal status "permission")
                (message "%s asks for permission" (alist-get 'name task)))))
  ```

  `roost-draft-task` opens the new task draft with a prompt of your own, for
  commands that start a task from what they show, such as a mail.
- `roost-watch-interval` (3 s), `roost-ssh-share-connections`.

A few variables tune Roost without being options, and may change between
releases; set them with `setq`. `roost-watch-unfocused-interval` (15 s)
is how often Roost refreshes while no Emacs frame has focus,
`roost-request-timeout` (60 s) how long a host operation may take,
`roost-startup-grace` (15 s) how long a task starts before Roost takes it
to wait at a prompt, and `roost-note-box-lines` (4) how many lines the box
for writing a note shows.

Each poll is one SSH command per host. Roost shares one connection per host
across them (OpenSSH `ControlMaster`, with its socket in the state directory and
closed a minute after the last request), so polls skip the handshake; set
`roost-ssh-share-connections` to nil to leave that to your ssh configuration.
Unreachable hosts are retried with backoff and keep their last known tasks,
marked unreachable.

### Where a task's skills come from

Roost does nothing with skills. The agent in a task finds its own, in the
task's worktree and in your home directory on the task's host, in the
folders its docs name (as they did in October 2026):

| Agent | In the project | In your home directory |
|---|---|---|
| Claude Code | `.claude/skills/` | `~/.claude/skills/`, and the plugins you install |
| Codex | `.agents/skills/` | `~/.agents/skills/` |
| Pi | `.pi/skills/`, `.agents/skills/` | `~/.pi/agent/skills/`, `~/.agents/skills/` |
| OpenCode | `.opencode/skills/`, `.agents/skills/`, `.claude/skills/` | `~/.config/opencode/skills/`, `~/.agents/skills/`, `~/.claude/skills/` |

So a skill in `.agents/skills/` reaches Codex, Pi and OpenCode, and one in
`.claude/skills/` Claude Code and OpenCode.

- **The project's.** Skills committed under a project folder come with
  every worktree. One you have made in the primary checkout and not
  committed doesn't, as `.worktreeinclude` copies only files Git ignores:
  started in a task, Claude Code 2.1.312, Codex 0.163.0 and Pi 1.3.0 list
  the committed skills and not the new one. Commit it, or have Git ignore
  it (in `.gitignore`, or in `.git/info/exclude` to keep it to yourself)
  and list it in `.worktreeinclude`, as `.agents/skills/review/`.
- **Your own.** Skills and plugins in your home directory reach every task
  on that host.
- **On another host.** Roost copies only its helper to a remote host, so a
  task there has that host's skills and plugins, not this machine's.
  Install the ones you want on that host yourself, from a dotfiles
  repository or the same plugin marketplace.

## How it works

Emacs talks to a small standard-library Python helper on each host, over SSH
with JSON on stdin and stdout. All requests are asynchronous; the dashboard
draws from a local cache. The helper creates worktrees, starts each agent under
a runner in its own tmux window, and records the task.

Status comes from each agent's native lifecycle events: Claude Code hooks passed
with `--settings`, Codex hooks passed per invocation, a Pi extension, and an
OpenCode plugin; with
`roost-program-status` on, also from what the agent reports to its terminal.
Roost never changes your global agent settings or answers prompts.

Each status, and what Roost makes of it, is in [What a task says](#what-a-task-says).

The helper notes each change of a task's status, of whether you've seen its
agent since its last event, and of what of its pull request or work waits on
you, in a file a day under `history` in its state directory, and deletes
files older than 30 days. Only Emacs asks GitHub, so it tells the helper when
a task's pull request or conflicts come to wait on you, or stop.

A task's identity is its host and ID. A per-pane ownership tag keeps Roost from
steering or killing an unrelated pane after a tmux restart, and hooks from an
earlier run cannot overwrite a resumed one. Merging needs the task's worktree
clean. With the primary checkout on the task's integration branch, the merge
happens there and needs nothing uncommitted (untracked files stay); with it on
another branch, Git merges into the integration branch without touching your
checkout (Git 2.38 or newer). A merge that conflicts leaves nothing changed.
One that a commit hook in the primary checkout refuses is undone, leaving
what the hook changed in other files. Nor does Roost change anything when it
refuses, saying what to do first: to merge a task whose worktree is locked,
was moved, or is in the middle of a rebase, cherry-pick, revert or bisect,
or into a branch whose rebase is under way. Neither a merge nor `u` writes
over or deletes a file Git ignores in the checkout it merges in, such as
your `.env`, as Git itself would without asking: Roost names it, for you to
move aside.
Branches are deleted only if they still point at the commit Roost verified.
Removing a worktree deletes the repositories of its submodules, which may
hold the only copy of commits made in them. Retiring removes one only when
they hold nothing their remotes lack, as when an agent checked them out to
build; otherwise it says which submodule holds what, for you to push.
Discarding counts those commits among what it would lose.

Things to know:

- Claude Code and Codex run no hook when you answer a permission request, so
  Roost looks for itself. A Claude Code command you approve shows `running` at
  the next poll, once Roost sees it start; declined, or stopped with Esc, the
  task shows `interrupted`, read from its transcript. Codex's hooks say when
  you decline or press Esc. Claude Code's other tools, and Codex, may keep
  showing `permission` until the agent moves on, and `e` asks before sending
  to a task in that state. With `roost-program-status` on, both say so
  themselves, at once.
- In auto mode, Claude Code refuses some commands without asking: the
  task stays `running`, and Claude's reply says what it refused. A
  dangerous `rm` asks for two minutes, and is refused if you don't
  answer; the task shows `permission` until Claude's next step. Once it
  has refused five commands, Claude may end a turn by offering to teach
  auto mode about your environment, which no hook reports: the task shows
  `ready`, but a prompt sent from Roost goes to the offer, so answer it in
  the terminal first. With Claude's sandbox on
  ([Sandboxes](#sandboxes)), a command that needs a new network host
  asks too: the task shows `permission` about six seconds later and,
  once you allow the host, until the command ends.
  With `roost-program-status` on, Claude says at once that it asks,
  naming the host, and that it goes on once answered or refused.
- Pi has no permission prompts of its own, but an extension can ask, as one
  that asks before each command does. Pi 0.84.4 and later say when such a
  dialog waits on you, and Pi 1.1.0 and later when you stop a turn with Esc;
  with older Pi a task shows `running` through a dialog and `ready` after Esc.
- OpenCode loads Roost's plugin from `OPENCODE_CONFIG_CONTENT`, which it
  merges over your own config; Roost adds its plugin to any you set there,
  which must then be plain JSON. Its command can't hold `--pure`, which
  leaves plugins out, or a project folder, which would take OpenCode out of
  the task's worktree, and a task won't start with `OPENCODE_PURE` set. An
  OpenCode the agent runs itself, as `opencode run`, says nothing to Roost.
  With turns in several sessions at once, the task works until the last
  ends, and waits on you while any asks. OpenCode asks before a tool only
  where your `permission` config says `ask`, and by default runs most
  without asking. Its questions, and a subagent's, show as `permission`;
  Esc, or declining a request, shows `interrupted`. OpenCode starts a
  conversation at its first prompt, so a task stopped before one starts a
  new conversation on `s`.
- Roost's task sessions stay out of the corner where tmux-control names other
  sessions with new output, and its terminals don't show that corner: it
  lights up whenever an agent prints anything, and only shows its terminal.
  Roost tells you when an agent needs you, and `n` or a click on `Roost:N`
  switches to the task.
- Since 2.1.284 (2026-09-28), Claude Code starts in auto mode unless a
  permission mode is set, approving most commands itself, so its tasks
  rarely ask. To be asked before each command, add
  `"--permission-mode" "manual"` to Claude's entry in `roost-agent-commands`.
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
  command stays the same across Roost upgrades. Until you trust them, Roost
  can't tell when Codex starts or ends a turn, even with
  `roost-program-status` on: Codex reports work between turns too, as while
  a command it left running runs. Codex's sandbox keeps a worktree's shared
  `.git` read-only, so it asks before committing.
- A GitHub issue's text goes to the agent as written, and anyone can open an
  issue on a public repository. Read it in the draft before pressing `C-c C-c`.
- Where you last looked at a task is a commit: its `HEAD` when nothing is
  uncommitted, or else one the helper makes of everything in the worktree,
  staged in a copy of its index, so your index, staging and branches stay
  as they are. No branch or other ref points at it, and Git prunes it with
  other unreachable objects, after two weeks by default
  (`gc.pruneExpire`); Roost then compares from the `HEAD` of that time.
  Untracked files over 1 MB are left out, then and since.

## Security

Roost is not a sandbox. An agent runs as you, with your permissions and
credentials on its host, and its own permission prompts and sandbox
([Sandboxes](#sandboxes)) decide what it may do without asking. Roost
never answers them. A remote host is trusted
as any SSH login is. [SECURITY.md](../SECURITY.md) says how to report a
problem and which inputs are worth scrutiny. Each line below can be
checked against `roost.el` and `scripts/roost_remote.py`.

What runs where:

- Emacs runs the helper as `python3 -I -c CODE`, on a remote host through
  `ssh -T -o BatchMode=yes`, which uses your keys or agent and never asks
  for a password (`roost--python-command`). `CODE` names only the state
  directory and the helper's file. The request goes on stdin as JSON, from
  a temporary file when it is over 4 KB, so nothing you type goes through
  a shell. `-I` keeps Python from importing anything from the directory
  it runs in.
- The helper's source goes over the same connection, on stdin, and is
  saved in the host's state directory as `remote-` and the first 16 hex
  digits of its SHA-256 (`roost--helper`, `roost--request`), so a new
  version of Roost installs a new file. One that no task uses is deleted
  once it is a week old.
- The helper runs `git`, `tmux`, `gh` and the agent with each argument
  separate, not through a shell. The command lines that tmux and Claude
  Code and Codex hooks hand to a shell, to start an agent's runner and to
  report its events, are quoted with Python's `shlex.join` and hold only
  Python, Roost's files in the state directory and the task's IDs. The
  other shell commands are your `roost-setup-command` and
  `roost-teardown-command`.
- When the helper measures a task, keeps where you last looked at it, or
  checks it is clean, Git runs no program that config names for its file
  system monitor, diffs or signatures, which an agent may write for a
  submodule or a worktree though its sandbox ([Sandboxes](#sandboxes))
  keeps it out of the repository's own config: `core.fsmonitor` is off
  there unless it is Git's own monitor, `log.showSignature` is off, and
  diffs take `--no-ext-diff --no-textconv`. Clean filters, as Git LFS
  uses, and merge drivers still run, as when checking for conflicts, and
  merging runs your hooks.
- Each agent starts under the helper's runner, in a tmux window of its
  own. Its hooks, Pi extension or OpenCode plugin run the helper with each
  event on stdin, and the helper records it and prints nothing back: they
  report, and never approve or decline. The runner and hooks run the
  helper's file with the same Python, without `-I`.
- Claude Code and OpenCode may read one folder outside the task's
  worktree without asking: the task's attachments, under the state
  directory, given to Claude Code as `--add-dir` and to OpenCode as a rule
  allowing it.
- Roost won't paste a prompt into an agent that is starting or asking for
  permission unless you confirm, as the paste could answer its menu.

Files:

- Each host keeps task records, hook settings, worktrees, attachments, the
  status history and the helper in `roost-state-directory`
  (`~/.local/share/roost`), which Roost creates with mode `0700`. Records
  are written to a new file from `mkstemp`, which only you can read, and
  renamed over the old one, so none is ever half-written.
- This machine keeps the hosts and projects you used, and review notes not
  yet sent, in the `roost` folder of `user-emacs-directory`, each file set
  to `0600`.

The network:

- Roost reaches other machines only through `ssh`, to the hosts you add,
  and TRAMP over it for a remote task's worktree; `git` on a host, to
  fetch and push a task's branch for its pull request, to delete that
  branch once it is merged, and in `roost-doctor` to try a push with
  `--dry-run`; and `gh` on a host, for issues, pull requests, their checks
  and comments. It sends nothing anywhere else: no telemetry and no update
  checks. Agents reach their own services as they would without Roost.
- Roost listens on no socket of its own. Hooks report by running the
  helper, which writes the task's record. The sockets involved are tmux's
  server and, with `roost-ssh-share-connections` on, ssh's shared
  connection, kept in the local state directory, which Roost sets to
  `0700`.
- Roost doesn't start an Emacs server. With one you started, a click on a
  terminal-notifier notification runs `emacsclient` to open the task.

What Roost never does:

- answer an agent's prompts: no key approves or declines for you;
- change your global agent settings, such as `~/.claude` or `~/.codex`:
  each agent gets Roost's hooks when it starts, for that task alone;
- stage what is left uncommitted, yours or an agent's, or commit it to a
  branch: merging needs the task's worktree clean, and takes only what
  its branch holds. Where you last looked at a task is kept in a commit
  no branch points at, made with a copy of the index, until Git prunes
  it (see [How it works](#how-it-works));
- delete commits no other branch holds, or uncommitted or untracked
  files, unless you discard the task and type its name. Removing a
  worktree, as merging and retiring do, deletes the files Git ignores in
  it, such as build output or a `.env` made there.

Dependencies: Emacs 29.1 or newer, transient, tmux-control and the Eat
terminal it uses, and on each host tmux, Git and Python 3.9 or newer. The
helper is one file of Python's standard library.

### Sandboxes

Claude Code and Codex can each run the commands they start in a sandbox
of their own, which limits what those commands may write and reach on the
network. Each works in Roost's tasks. Whether it is on is yours to choose,
in the agent's own settings: Roost never writes them. As of 2026-10-25,
with Claude Code 2.1.303 and Codex 0.163.0:

- Claude Code's sandbox is off by default. Turn it on with
  `"sandbox": {"enabled": true}` in the project's `.claude/settings.json`
  or your own `~/.claude/settings.json`, and add
  `"allowUnsandboxedCommands": false` beside `enabled`, so that a command
  the sandbox stops can't run again outside it. It covers shell commands
  only: Claude's file tools, MCP servers and hooks run outside it, Roost's
  hooks among them, so tasks report their status as before. Commits work
  in a task: in a linked worktree, the sandbox lets commands write the
  main repository's `.git`, except its `hooks/` and `config`
  ([Claude Code's docs](https://code.claude.com/docs/en/sandboxing)).
- Codex's sandbox is on by default. It keeps `.git` read-only by design, a
  worktree's shared one included, so Codex asks before each commit
  ([openai/codex#14338](https://github.com/openai/codex/issues/14338)).
  Don't widen it to the Git directory with `--add-dir` or `writable_roots`
  to stop those questions: a sandboxed command could then write Git
  settings that run, outside the sandbox, at the next Git command, yours,
  Roost's or Magit's.
- Pi has no sandbox of its own. Its repository has an example extension
  that runs Pi's commands in one, built on Anthropic's sandbox runtime; it
  hasn't been tried with Roost.
- OpenCode has none, and its security policy suggests a container or a VM.

A VM you reach over SSH is an ordinary Roost host, and keeps a task's
worktree, its Git and its agent inside the VM.

On a Linux host, Claude Code's sandbox needs `bubblewrap` and `socat`. On
Ubuntu 24.04 and later, Ubuntu's stock AppArmor policy can make every
sandboxed command fail with `apply-seccomp: write /proc/self/setgroups
(nested userns is capability-restricted; caller must provide
CAP_SYS_ADMIN): Permission denied`, as it did for Claude Code 2.1.310 on
Ubuntu 26.04.1 on 2026-10-25
([anthropics/claude-code#101946](https://github.com/anthropics/claude-code/issues/101946),
open then). This command checks for it, and changes nothing:

```sh
bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user cat /proc/self/attr/current
```

If it prints `bwrap//&unpriv_bwrap (enforce)`, the policy applies, and
there are two ways out:

- Set `"sandbox": {"network": {"allowAllUnixSockets": true}}` in your own
  Claude settings on that host. It needs no root, and the sandbox still
  limits writes, but sandboxed commands can then reach any Unix socket,
  such as D-Bus or Docker's.
- With root, replace Ubuntu's `bwrap-userns-restrict` profile with the
  one in Claude Code's docs, as
  [a comment on that issue](https://github.com/anthropics/claude-code/issues/101946#issuecomment-6372201031)
  describes. This lifts Ubuntu's restriction for every program that uses
  bubblewrap, such as Flatpak.

Codex's sandbox works on such hosts, since it needs only one level of
bubblewrap.

## Development

`make test compile` runs the ERT suite, the Python lifecycle tests against real
Git and isolated tmux sockets (fixture agents drive the actual hook commands,
without model calls), and a warning-free byte-compile. CI runs it on Emacs 29.1
and 30.1, except for a change only to Markdown files or `docs/`, which no test
reads: then its checks pass without running it. The tests of Roost in Magit need Magit and its dependencies on the
load path, as `make test TEST_LOAD_PATH="-L …/magit/lisp -L …"`, Evil
and evil-collection for its Evil keys there, and perspective.el for the tests
of task perspectives in it; without them they are skipped.

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
- a click on a task's row, from that window or the one beside it, and with
  the task still listed or gone since, that asks in the minibuffer rather
  than opening the task, showing a menu, or saying why it can't: a
  completion popup hides a question once you click elsewhere;
- a key the task panel tells you to press that isn't bound there, or whose
  command doesn't apply to the task;
- a view, the task list, or finding the task of the tab you're in, that
  allocates twelve times as much or more for eight times the tasks: its cost
  grows faster than the number of tasks, as when each row looks through
  every task. Allocation is counted, not time, so it is the same on any
  machine.

Hosts, processes, terminals, Magit, the menu and the browser are stubbed, and
every question is answered with `C-g`. A new button or key is covered as it
is. A new kind of task needs a state in `roost-sweep--gallery`, and a new view
an entry in `roost-sweep--views`.

The commands that quote what you are looking at read buffers Roost doesn't
make. The sweep runs each in a gallery of buffer states, `roost-sweep--buffers`
(narrowed, read-only, indirect, an Org source block being edited, no file, a
remote file, a rectangle, CRLF line endings, a task's worktree and others), and
in Org entries, agenda lines and narrowed Magit diffs, and fails on a Lisp
error, a connection to a host TRAMP isn't connected to, a file or lines that
aren't where the quoted text is in the whole file, quoted text that isn't the
region's, or a change to your buffer.

`make qa` uses Roost as you would, in a GUI Emacs of its own: a plain
configuration with its own server, state directory and tmux socket, and
`test/fake_claude.py` for Claude Code, so Git, tmux and the host helper are
real and no model is called. `test/qa/fake_gh.py` stands in for `gh`, with
what each journey has GitHub say. The run has a home directory of its own, so your
tmux, shell and Git configuration don't change it, and the fake agent writes
its transcripts there, as Claude Code would in yours, for search. Its journeys start a task from the menu, answer
it in its terminal, go through the tasks waiting with `n` and back, fold and unfold a long prompt with the mouse, resize the
frame, merge a commit, review a change in Magit and send a note, edit,
cancel, remove, send and discard review notes, work in the
terminal with tmux-control's own keys (split a pane, open and move between
tmux windows, switch to another task and back), open a shell beside the
agent, use the dashboard, turn the panel and sidebar off and on, stop and
resume an agent, retire a task or discard its work, discard a task by
typing its name and from its row's menu, send a prompt, bring a
task up to date, restart Emacs with agents at work, search the
conversations, work in a second frame, start a task from an Org heading,
draft one from a compilation error, a file and a URL, change a draft's
project, agent and GitHub issue, quote a region or a Flymake warning from
a task's file, keep a tab per task, two of the same name among them, forget a task, fork
one's commits, follow a pull request from GitHub's checks and review to
its merge, resume an agent that exited, see a host it can't reach,
check the setup with `roost-doctor`,
read back through a long reply in tmux-control's scrollback, move between
agents that all print at once, reconnect a terminal whose connection
dropped, and forget a host with tasks on it. One leaves something unfinished, as you do (`M-x` or Roost's own
question open, its menu, a draft, a task whose host hasn't replied yet, a
mouse press in a terminal that never let go, a review note half written,
the question before discarding a task), and
then goes to a task another way: a click, `l`, `n` or `t` in the sidebar, a
click on a notification, or a click in the terminal. They press keys
and click through Emacs's command loop. A menu or dialog of the system's
own, which a right click or a question after a click opens, would hold Emacs
up, so the journey says beforehand what you would choose in it. After each step it checks for Lisp errors, in
commands, timers and process filters alike, for a backtrace, for lines of
Roost's views cut off at the window's edge, for another task's terminal
beside the current task's, for a terminal that shows other than what
tmux has in its pane, or history nobody scrolled it to, and for a question
open in the minibuffer that you aren't in, unless the journey left it so,
or anything Roost holds back until such a question is done. With tmux-control's
`tmux-control-pause-log-mode`, it also fails a step in which Emacs stopped
responding for a second or more, and says what Emacs was doing and how
often the step's keys and clicks had it collect garbage, with what their
commands set off, such as Roost's timers: many times, and the pause was
that garbage; few, and the machine's load more likely. A key sequence or
click that has Emacs collect garbage more than 20 times fails its step
too. It runs the
sweep where text is measured in pixels, too. It takes about 25 minutes,
writes `report.html` with each step's windows, the echo area and, on macOS, a
screenshot, and fails if anything was wrong. The report ends with the commands
of Roost and tmux-control that no journey ran: where the next journeys should
go. A problem known to come from elsewhere, such as a bug in tmux-control
awaiting its release, is marked `Known` in its journey: it is reported,
without failing the run, until it stops happening. Look at the
screenshots too: the checks don't see what merely looks wrong. Emacs needs
tmux-control and its dependencies:

    make qa QA_FLAGS="-L ../tmux-control --package-dir ~/.emacs.d/elpa"

Package directories are read, never written. `--load FILE` in `QA_FLAGS` loads
Emacs Lisp after Roost, such as a change to try, and `--keep` leaves the Emacs
and its tmux server running. A new flow gets a journey in `test/qa/qa.py`.
Name journeys after the options, as `test/qa/qa.py` names their functions,
to take only those:

    make qa QA_FLAGS="-L ../tmux-control --package-dir ~/.emacs.d/elpa merge walk_away"

Three options take the same journeys elsewhere. `--remote` puts the tasks on
`qa-remote`, a host reached over SSH as yours are: `test/qa/fake_ssh.py` stands
in for `ssh` and runs each command here, with its own home, delaying what goes
each way by `--latency` seconds (0.15 by default). Roost's requests,
tmux-control's connections and TRAMP all go through it, so replies arrive as
late as a remote host's do, which is where races between them show. Magit's
review is left out there: over TRAMP's `ssh` method it takes most of a minute.
`--tuned` gives Emacs settings many configurations have: pixel scrolling, a
1 GB garbage collection threshold, tmux-control's idle collection, and pane
directories, which make a remote terminal's directory a TRAMP one.
`--popular` adds packages many configurations have, from `-L` or
`--package-dir`: vertico in vertico-posframe's popup, which hides a question
you click away from, recursive minibuffers, and perspective.el, a
perspective for each task. Pass them in `QA_FLAGS`, as make takes long
options for itself:

    make qa QA_FLAGS="--remote --tuned -L ../tmux-control --package-dir ~/.emacs.d/elpa"

The agents update often, and Roost relies on what they report.
`make contract` scans each installed agent for the events and fields Roost
reads, and names any it has not seen: Claude Code's hook events,
notification types and payload fields; the hook events Codex's binary
describes; the extension events Pi's types declare; and the events OpenCode
defines. An agent that isn't installed is skipped. `make contract-live`
also takes Claude Code through real sessions (short Haiku turns, about
seven minutes) and checks each status Roost derives: in manual mode, a
reply, a permission request approved and declined, Esc, a minute idle and
`/clear`; in auto mode, as Claude starts with no mode set, a command it
lets run, one it refuses and a dangerous `rm` left to time out; and with
Claude's sandbox on, from a branch of the scratch repository whose
settings turn it on, a sandboxed command, a new network host allowed and a
command approved outside the sandbox.
`make contract-live CONTRACT_AGENTS="codex pi opencode"` does the same
with Codex (its default model; trusting the scratch repository and Roost's
hooks is undone afterwards), and with Pi and OpenCode (the model each is
set to use), which also get a message while they work. Add
`CONTRACT_FLAGS=--program-status` to relay their OSC 7501 reports too, as
`roost-program-status` does. Run them after an agent updates. A Claude
Code older than an event Roost listens to runs none of Roost's hooks, so a
new event in `CLAUDE_HOOK_EVENTS` raises `CLAUDE_MIN_VERSION`, which
`roost-doctor` checks.

A live run that passes keeps what the agent reported in `test/captures`,
named after the agent and its version: each hook payload or extension
report, and each relayed status report, in order, with paths and ids
replaced. `make test` reads each capture again and checks that Roost makes
the same of every event as it did then, so a change to an adapter is tested
against what real agents sent, not only what the tests suppose. Captures of
older versions stay, as hosts may run them. When a change is meant to read
them differently, `python3 test/agent_captures.py` writes their expectations
again, and the diff shows what changed.

| Agent | Captured | Scanned | How Roost hears it |
| --- | --- | --- | --- |
| Claude Code | 2.1.303, with and without relay; 2.1.310 relayed | hook events, notifications, payload fields | hooks given with `--settings` |
| Codex | 0.163.0, with and without relay | hook events and payload fields | hooks given with `-c`, reviewed once in Codex |
| Pi | 1.3.0 | extension events, context, options | an extension given with `--extension` |
| OpenCode | 1.19.4 | events, settings | a plugin named in `OPENCODE_CONFIG_CONTENT` |

See [validation](validation.md) for the live runs with Claude Code, Codex and
Pi on local and remote hosts, [the demo notes](demo.md) for how the screenshots
were made, and [MELPA](melpa.md) for the package recipes.
