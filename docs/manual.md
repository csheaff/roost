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

Requirements: Emacs 29.1+ built with dynamic modules, and the two packages
that draw a task's terminal: [Ghostel](https://github.com/dakra/ghostel)
0.65.0+ and [ghostel-tmux](https://github.com/dakra/ghostel-tmux) 0.4.0+.
Ghostel offers to download its native module the first time a terminal
opens. Each task host needs
Python 3.9+, Git, tmux 3.1+, and an installed, signed-in agent CLI (Claude Code
2.1.78 or newer, Codex 0.160.0 or newer). Remote hosts need key- or agent-based
SSH; use SSH config aliases for ports and jump hosts. Roost copies its helper to each host itself.

Roost runs Claude Code, Codex, Pi and OpenCode, and means to support a few
agents well rather than many loosely: each is tested against the real
agent, whose releases can change how it reports its status, resumes and
takes hooks. An agent gets an adapter when it is widely used, reports what
it is doing through hooks or events Roost can read, and keeps its launch
and resume arguments stable. Roost can't start an agent it has no adapter
for.

Emacs 30 (built-in `use-package`), with Ghostel from MELPA:

```elisp
(use-package ghostel :ensure t)

(use-package ghostel-tmux
  :vc (:url "https://github.com/dakra/ghostel-tmux" :rev :newest))

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

Emacs 29: `M-x package-install` ghostel, `M-x package-vc-install`
ghostel-tmux's URL, then Roost's, and
`(roost-watch-mode 1)`; for SSH hosts, `(setq roost-hosts '(nil "devbox"))`.

straight.el:

```elisp
(use-package ghostel)
(use-package ghostel-tmux
  :straight (:host github :repo "dakra/ghostel-tmux"))
(use-package roost
  :straight (:host github :repo "csheaff/roost" :files ("roost*.el" "scripts"))
  :demand t
  :bind ("C-c r" . roost-dispatch)
  ;; :custom (roost-hosts '(nil "devbox"))
  :config (roost-watch-mode 1))
```

Doom Emacs, in `packages.el`:

```elisp
(package! ghostel)
(package! ghostel-tmux :recipe (:host github :repo "dakra/ghostel-tmux"))
(package! roost :recipe (:host github :repo "csheaff/roost" :files ("roost*.el" "scripts")))
```

and in `config.el`: `(roost-watch-mode 1)`, and for SSH hosts
`(setq roost-hosts '(nil "devbox"))`.

Then run **`M-x roost-doctor`**. It checks Emacs's side and, on each host, SSH,
Python, Git, tmux and each agent CLI's version and sign-in, with a fix for
anything missing. For pull requests it also checks the GitHub CLI, the GitLab
CLI for projects on GitLab, and whether Git on the host can push each project
you've used there (a dry run that sends nothing). `C-u M-x roost-doctor` checks a host before you add it.

Magit is optional (review falls back to Dired).

### Fitting your setup

- **Workspaces.** Each task gets its own window arrangement: a perspective with
  [perspective.el](https://github.com/nex3/perspective-el), otherwise a tab when
  `tab-bar-mode` is on, otherwise none: a frame shows one task, whose
  terminal takes the place of another's. `r`, `f` or `D` on another task's
  row opens its terminal first, then its Magit, files or diff. Retiring,
  merging, discarding or forgetting a task closes its workspace; files you
  opened in it stay open. Set `roost-workspace` to choose.
- **Evil.** Roost's dashboard and panels start in Emacs state so their keys work
  (`roost-evil-state`); `j`/`k` move between tasks. So do several images
  or a page an agent shows, and a terminal still connecting; over one
  image, `q`, `z`, `n` and `p` are Roost's in normal state too. Drafts
  start in insert state. In Magit, Roost's keys work in normal state, with the whole file's
  diff on `g=` (evil-collection uses `=`). A terminal is Ghostel's, with
  the Evil setup you give Ghostel;
  [`roost-task-opened-functions`](#configuration) can enter a state when a
  task opens.
- **Other modal setups** (Meow, xah-fly-keys): put `roost-dashboard-mode`,
  `roost-task-info-mode`, `roost-search-mode`, `roost-attempts-mode`,
  `roost-doctor-mode` and `roost-workload-mode`, and the drafts
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
(it can span lines), and press `C-c C-c` or click Create in the header line.
Roost creates the branch and worktree,
starts the agent in tmux, and opens its terminal.

**Start from where the work is.** Your task list can stay where it already is:

- Run `M-x roost-new-task` on an Org heading, or on its agenda line. The
  heading and its notes become the prompt, and the heading records the task (a
  `ROOST_TASK` property), so Roost commands run there, such as
  `roost-open-task` or `roost-review`, act on it. Set
  `roost-org-link-tasks` to nil to leave your entries as they are.
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
- Press `C-c C-t` in the draft to pick one of the project's open GitHub or
  GitLab issues.
  Its title and text become the prompt, and the task's pull request will close
  it.
- With [twg](https://developer.atlassian.com/cloud/twg-cli/), Atlassian's
  Teamwork Graph CLI, installed and signed in on this machine (`twg login`,
  then `twg setup default-site`), `C-c C-t` lists your open Jira work items
  too, by their keys, with their status and labels. One's summary and text
  become the prompt, and the task's name, and so its branch, starts with its
  key, as in `PROJ-123-fix-login`. Its text is its description, then each
  rich-text field it has, as some sites keep the text in a field of their
  own. Plain fields and comments stay out. Reading them takes one more call
  to twg as you pick; if that fails, a message says so and the prompt has
  what the list gave. Jira's own GitHub or
  Bitbucket integration, where your site has it, links the branch and its
  pull request to the work item by that key, and the pull request draft
  links back to it. Roost doesn't change the work item. `roost-jira-query`
  says which work items to list.

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
(`● Roost:2`, the dot in the colour of the most pressing, with a `!` after
the count while one asks; click it for the next one). `n` jumps to the next agent waiting
for you, permission requests first, and the echo area says which task it
opened, why that one waits and how many more do, as in `permission ·
ledger: Asks to run make test; 2 more waiting`; in a narrow frame, why it
waits is cut short first. Answer it in the terminal, then `n` again. Once
none waits, `n` says so and offers the way back to where you pressed the
first `n`: press it again to go there. With workspaces that is the
perspective or tab you were in; without, the frame's windows as they were.
A link the agent shows there, such as the pull request it opened, opens with
a click.
A finished agent whose reply you have seen stops counting, and turns grey,
until it replies again; one that failed or stopped by itself stops counting
once you've seen it. What you've seen is kept on the task's host, for your
other machines and the next session.

**Take the tasks an agent offers.** An agent
that comes across work outside its task, such as a bug in code it read,
offers it as a task of its own and goes on with its own work. The offer
waits, dim, under its task in the dashboard and sidebar
(`Fix add in calc.py  offer`), with its brief when you hover over it, and the
agent says in its reply what it offered. Nothing waits on you: the task's
own status is as it would be without it.

- Click it, or press `RET` on it, to open it as a new task draft, filled in:
  in the same project, with the same agent, starting from the branch the
  offering task merges into, named and prompted as the agent offered it.
  Opening it only shows it: the offer waits under its task until you create
  the task, have the agent do it, or dismiss it, so you can look and go
  elsewhere. Open it again and the draft is as you left it. The draft is
  like any other, with one more button, **Dismiss offer**; cancelling it
  leaves the offer waiting, and asks first only if you changed the brief.
  The task you create shows under the one that offered it, each task's
  panel names the other, and you stay where you were.
- `e` on it, or **Do it here** from its right-click menu, sends that agent
  `Do this task here: “TITLE”`, as `e` sends a prompt, and the offer no
  longer waits. The agent wrote the brief, so the title is enough.
- `x` on it, **Dismiss** from its right-click menu, or **Dismiss offer** in
  its draft, drops it. Roost can't tell whether an offer still stands, as
  when its agent did the work since: ask the agent, or dismiss it.

A task keeps at most three offers waiting, and one offered again by its
title changes its brief. An offer goes with its task, and the question before
you merge, retire, discard or forget the task names it. One its agent makes
while you read that question keeps the task, and Roost says which: ask again,
and the question names it. A new task starts
without the offering task's changes, and the agent is told so.

Roost gives the agent a tool, `propose_task`, from an MCP server of the
helper's, with a few sentences on when to use it, which cost tokens on each
of its requests; `roost-agent-offers` set to nil starts tasks without
Roost's tools. Claude Code, Codex, OpenCode and Pi each take it for the one
task, with nothing written to the agent's own settings, and run it without
asking you ([Security](#security) says how). How often an agent offers
rests on the model. This is an experiment: it may change or go.

- Pi needs 0.99.0 or newer, which has an MCP client. It is shown the tools
  but not the sentences on when to use them, so it offers when you ask it
  to. With Pi's MCP support turned off in its settings, Pi reports Roost's
  server as an extension's error when a task starts; `--no-mcp` in the
  task's command leaves it out.
- Roost's server is named `roost`, and for Codex `roost_task`: one of your
  own by that name in Pi's `mcp.json` stands in place of it, in OpenCode's
  config is replaced by it for the task, and in Codex's is mixed with it,
  so give yours another name.
- A Codex older than 0.163.0 that does not know a server's
  `default_tools_approval_mode` asks before each of the tools.

**See an image an agent shows.** Most agents send no images to their
terminal, so ask the agent to show you one, such as a screenshot or a chart
it made: it opens in a window beside the task's terminal, and you stay where
you are. The window is the size the image needs, up to half the terminal's
space: to its right, or below it for a wide image or a terminal with no
columns to spare. An image much taller than the window is as wide as it,
for you to scroll. Click the image, or type `z` there, and it fills the
frame; a click or `q` puts the windows back. The next image takes its
place, in a window resized for it unless you have resized it yourself, and
`q` there closes it. Shown while the task is off screen, it waits until you
open the task; another task's terminal takes it off the screen, and it comes
back when you open its own task again. The task's panel names the image it
last showed: click the name, or `M-x roost-show-image`, to bring back one
you closed. Roost keeps a copy on the task's
host, so it works on a remote host and after the file has gone, and the copy
goes with the task. The tool for this, `show_image`, comes with
`roost-agent-offers`, for tasks of any agent started since. It
shows a PNG, JPEG, GIF or WebP of at most 8 MB.

Ask for several at once, as a before and an after, and the agent shows them
together: up to six, of 16 MB in all. Roost lays them out in the rows that
draw them largest in the window, one over another or side by side, all at
one scale and each over its file's name, and sizes the window for them as
it does for one. Click one, or `RET` on it, and it fills the frame alone;
`n` and `p` there, or the arrows above it, show the others in its place,
and a click or `q` goes back to them all, beside the terminal.

**See a page an agent writes.** With `roost-agent-pages` on, as well as
`roost-agent-offers`, the agent can also show a small page of its own: a diagram of what it changed, a mock-up, or
controls to try, such as a slider. Ask for one in your own words, as in "show
me that as a page" or "a diagram I can click". It opens where an image does
and takes its place, and what moves in it works there. A page you ask to share
or publish is another matter: a Claude Code task makes that one with its own
Artifact tool, at claude.ai. Now and then it starts one for a page you only
asked to see; tell it to show the page here instead. A button in it that asks
the agent something opens a draft to the task with its words, for you to send:
nothing a page does reaches the agent until you do. The agent doesn't see its
page drawn, so tell it what looks wrong. It needs a graphical Emacs built with
xwidgets. The tool is `show_widget`, for a page of at most 512 KB, in tasks
started since you turned the option on. A Pi task on this machine shows its
page as the model writes it: the page opens as the model starts on it and
fills in from there, where the model's server sends a tool call's input as it
is written (LM Studio sends it whole, and the page then fills in at once).
Other agents' pages, and a Pi task's on another host, show once they are
whole.

**Keep them in view.** `b` in the dashboard, or `M-x roost-sidebar-mode`, keeps a
compact task list at the left of the frame, through `C-x 1`. With
perspectives or tabs, it shows in a task's workspace, and in one of your own,
such as perspective.el's `main`, only while that shows a task's terminal, so a
shell of your own there doesn't look like a task. Each task there is its name
and, at the right, its status ([What a task says](#what-a-task-says)). A
click opens the task,
quitting any question you left open in the minibuffer, which would hold it back,
and closing a menu left open. Each project's heading ends with a `+` that
drafts a task there. With perspectives or tabs and no task yet, there is no
sidebar to click: start the first with `M-x roost-new-task`.

**Talk first.** Below the sidebar's tasks, "New conversation" opens an agent's
terminal at once, in no project of yours, with nothing to write first: you
say what you want in its terminal. A conversation is a task like the others,
in a repository of Roost's own in the host's state directory, listed under
"Conversations"; it has no branch to merge, so `x` just ends it.
`roost-new-conversation` (`C` in the menu) does the same, and with `C-u`
asks which host. A conversation is where to plan: ask its agent to look at
one of your projects and split a piece of work into tasks, and each waits
under the conversation, naming its project, for you to open as a draft
there and start ([Take the tasks an agent offers](#a-day-with-roost)). It
reads the projects that host has run tasks in without asking, and changes
nothing in them without asking. Claude asks once whether to trust Roost's
conversations folder, with the first conversation on a host.

**Start in another project.** Under "Start a task in", the sidebar lists the
projects with no tasks now that you used last on each host, three
(`roost-sidebar-recent-projects`), and "Other directory…". A click on one, or
`RET`, drafts a task there, taking a draft you have written there too, unless
it quotes files of its project, forks a task there or starts from an issue
there; "Other directory…" first asks for a
host, then a folder there, which after a click is the system's folder dialog
for one on this machine. `X` on a project, or "Forget" on its menu, stops listing it until
you start a task there again.

**Read a task's panel.** `I` docks a panel at the right of an open task's
terminal, kept current as the agent works. It is quiet until something is wrong: bold is
the task's name, and colour is what wants you, which comes first, under the
name, after a `▲`: its worktree on another branch, a merge under way or one
that would conflict, its worktree gone, its last error. Then what to do next,
the files it changed, those not yet committed first, and what a merge would
rest on (below). While the agent works, the line under its name says what it
is doing, as `Running make test`. At the foot, a row of keys opens the task's
other views (`r Magit`, `f Files`, `t Shell`, `? More`), and two dim lines
fold what you seldom need there: your latest prompt, a reminder of where you
left off that the terminal may have scrolled away, and the details of where
the work lives. `RET` or a click on either unfolds it.

A click or `RET` on a file
opens its diff in Magit, in a buffer of its own, as Magit's diff of the file
you visit has, so another file's diff, in the same window, leaves it open behind (`magit-diff-buffer-file-locked`
set to nil keeps one buffer for all). There `;` writes a note for the agent (more under
Review in Magit, below). The terminal shows the agent's replies, so the panel leaves them out
while the terminal is on screen; `i` shows the same panel in the main area,
with the latest reply after the changes (a click or `RET` opens a link in it), until
its task opens there and the panel docks. `?` in the panel
opens the menu of what you can do with the task. Each key the panel names
can be clicked too, with the words that go with it: a click on "m merges
it" does what `m` does there. The panel steps aside
when the terminal would drop below 80 columns, and `q` in it turns it off.

**Check the work yourself.** `t` opens a shell beside the agent, in the same
worktree, and returns to it after. Run the tests, start the app, poke at it.
The agent and the shell are tmux panes, each in a window of its own: `C-x o`
moves between them, and so does `C-t o`. tmux's own keys work after `C-t`,
as they do after its prefix in a terminal: `C-t %` splits off another pane,
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
lines, and `@` drafts a prompt holding all of them; sending it clears those it
still holds as they were, and one you took out or changed stays. `=`
on a file shows the whole file with its changes marked, and you can still
stage there.

**Catch up and finish.** When other tasks land first, the dashboard shows the
task falling behind (`↓2`). If merging the task's commits would then
conflict, a notification says so, and the task panel and menu say so before
you press `m`, as in
"Conflicts with main in ledger.py: `u` merges main into it, to resolve them
there", and once
you've seen what its agent last said, the task says `conflicts` and counts
as waiting: `n` visits it. Roost checks whenever the task's branch or the
integration branch moves, with `git merge-tree` on the task's host (Git
2.38 or newer; older Git doesn't check). For a task with an open pull
request, GitHub or GitLab says whether it conflicts instead. The panel also names
other tasks of the project that change the same files, committed or not,
in one line ("ledger totals and report chart also change report.py"),
which may conflict once one of them merges. `u` merges the integration branch into the task's
own worktree. If that conflicts, Roost offers to have the task's agent resolve
it, run the tests and commit. With Git's `rerere.autoUpdate`, Git may resolve
the conflicts as you resolved them before and stage them; the merge then stays
under way, and Roost offers to have the agent check those resolutions and
commit it. Then `m` merges the task into its integration
branch and removes its worktree, branch and window. For work you don't
want, `x` discards the task, first saying what that loses. An agent can go
on working while you read either question: a branch that has moved isn't
merged, and a task that holds more than you were told isn't discarded. Look
at it, then ask again.

**Or open a pull request.** To finish on GitHub or GitLab instead, `P` drafts one: the first
line is the title and the rest the body, prefilled from the agent's commit
message. `C-c C-c` pushes the branch and creates it (`C-u C-c C-c` as a draft).
The dashboard then shows `#12` with its checks and review, as it does for a pull
request the agent opened itself from the task's branch. Send review feedback
to the agent with `e`; when it has committed, `P` pushes the new commits and
opens the pull request. Once it is merged, `x` retires the task and deletes the
branch. After one closed, or merged with commits since, `P` drafts another. If
the task has one by the time you create yours, as its agent opened, `C-c C-c`
pushes to that, and your text stays in the draft. Needs `gh` on the task's host,
or `glab` for a project on GitLab, and Git credentials there that can push.

**On GitLab.** Roost asks GitLab, through `glab`, when the host of the
project's `origin` says so by name, as `gitlab.com` and `gitlab.example.com`
do. For a GitLab server whose name doesn't, run `git config roost.forge
gitlab` in the project (`github` the other way). Roost calls GitLab's merge
requests pull requests too, and numbers them as GitLab does, `!12`. Their
pipeline's jobs are the checks: one allowed to fail passes when it does, as
the pipeline does, and a manual job not allowed to fail waits. Their
unresolved threads are the review threads, and reviewers who haven't
reviewed yet are the reviews still asked for. On any other forge, Roost
knows nothing of pull requests, and `P` says so before pushing: merge with
`m`, or push and open one there yourself.

What each task's row, panel and notification say is in
[What a task says](#what-a-task-says).

## What a task says

The sidebar and the dashboard give each task a word after its name. The
table's second column says when a task waits for you: those are the tasks
`n` visits, the mode line counts and a notification announces. In the
sidebar, their word is in its colour; it is plain for `merged`, dim for an
agent only working or stopped, and an agent you've seen that waits for
nothing has none. Where a sidebar is too narrow for a word beside a
dozen columns of the name, a mark in the word's colour stands for it at
the row's end: `?` for a task that asks something of you, `!` for
something that went wrong, `●` when it is your turn and `◌` while the
agent works (`*` and `~` where your display can't draw those). A row
with neither is stopped, merged or exited, on a host that is away, or
waits for nothing. The row's help, when the mouse is over it,
says the word. The dashboard shows every task's word, and counts
them by those words at its top, what can't go on without you first. In
the dashboard and the task panel, the dot before a task's word is dim
when the task waits for nothing, but for one that failed, crashed or hit
an error, which keeps its colour once you've seen it.

| Word | Waits for you | What it means |
| --- | --- | --- |
| `permission` | Yes, before the rest | The agent asks something, or a dialog of its waits; answer it in its terminal |
| `starting` | Once it seems held at a startup prompt, such as folder trust | The agent is starting. Without `roost-program-status`, Codex reports its status only from its first turn |
| `ready` | Until you've seen its reply | Its turn is over and it waits for your next prompt. Not "reviewed" or "done" |
| `interrupted` | Until you've seen it | You stopped its turn, with Esc or by declining a request |
| `error` | Until you've seen it | A turn ended on an API error, such as a usage limit; `RET` opens it to try again |
| `failed`, `exited` | Until you've seen it | The agent's CLI failed, or it exited; `RET` shows its last output, and `s` resumes its conversation. An agent you start again from a shell sends Roost nothing, so `s` waits until it has exited |
| `crashed` | Until you've seen it | Its tmux pane went, as when the host or its tmux server restarted; `RET` or `s` resumes its conversation, and asks once to resume every other agent that crashed on that host. Those stopped, exited or failed stay as they are |
| `conflicts` | Once you've seen its reply | Merging its commits into the branch it merges into would conflict; `u` brings that branch in |
| `to merge` | Once you've seen its reply | Its pull request passed its checks and review, and GitHub or GitLab finds nothing else in its way; `P` opens it |
| `ci failed` | Once you've seen its reply | A check of its pull request failed |
| `comments` | Once you've seen its reply | A review thread on its pull request is unresolved, Copilot's too |
| `running` | No | The agent works on a prompt |
| `background` | No | Claude's background work, or Pi's queued messages, remain. Claude counts a teammate, a named agent it can send to, even once it idles, so a task reads this after every turn once its session has started one; `x` offers to stop it and finish with the task |
| `stopped` | No | Stopped with `K`; `s` resumes its conversation |
| `merged` | No | Its work is merged, on GitHub or GitLab or into its branch; `x` retires it |
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
GitHub or GitLab last said, and counts those that passed. Without a pull request, or
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
  GitHub or GitLab finds no conflicts, nor does GitHub say that branch rules
  block it or that it needs updating. `P` opens it.
- `ci failed`: a check failed.
- `comments`: a review thread is unresolved, Copilot's too, even one the agent
  answered and left open.

A failed check or a new thread waits two minutes first: an agent that watches
its own pull request takes it up by then, and shows as working. The status
lasts until the pull request changes or the agent starts again, whether or not
you've seen it. Before that, the task panel says what the pull request waits
for, such as its checks or Copilot's review. Roost only says when it's your
turn: `e` tells the agent what to fix. It goes by what GitHub or GitLab said after the
agent's last push, while the branch has no commits the pull request lacks and
nothing is left uncommitted or in the agent's own worktrees. A commit made there,
as by GitHub's Update branch button or an applied suggestion, isn't one it lacks:
Roost fetches it, once, to compare it with the branch.

### A pull request left to its agent

`L` leaves a task's pull request to its agent, and `L` again takes it back;
`roost-leave-pull-requests` leaves those of new tasks. Left, a failed check,
an unresolved review thread or a conflict with the branch it merges into
doesn't wait on you first. After the same two minutes, Roost tells the
agent, in one line of its own:

    Roost: A check failed on #12. Fix it.

The agent's terminal shows it among your prompts, and the agent goes to work
as if you had pressed `e`. The task panel says the pull request is left to
its agent and what Roost last told it. It works the same with every agent,
as Roost does the telling.

- Roost writes the line itself, from what waits and two numbers. What a
  reviewer wrote isn't in it: the agent reads that from GitHub or GitLab.
- It goes once for each thing: a failed check or a conflict once for each
  commit the agent pushes, review threads once, and after that only when a
  comment came since the agent last did anything.
- Only while the agent rests at its prompt after a turn it ended itself,
  and you aren't at its terminal, writing it a prompt, or just done
  sending one. One that asks, one you stopped and one that has exited wait
  for you.
- An agent you prompted from somewhere Roost doesn't see, such as another
  terminal or the Claude app, is told nothing of how the pull request was
  before that turn: Roost looks again, and tells it only of what is still
  there.
- Five times at most for each kind on one pull request. After that, or when
  the agent stops with the pull request as it was, the task waits on you as
  before, with its word and a notification. `L` twice starts the count again.
- Roost never merges: `to merge` is always yours.
- Emacs has to be running, as only Emacs asks GitHub or GitLab.
- Roost can't see a prompt you left half typed in the agent's terminal
  before going elsewhere: the line would join it.

### Work that is merged

A task whose work is merged, on GitHub or GitLab or into the branch it
merges into, says `merged` in the dashboard and sidebar once you've seen its
agent's last reply, so you can tell which tasks to retire without opening them.
Nothing is lost by retiring it with `x`: nothing is left uncommitted, and its
commits are all in what was merged. Commits made after its pull request merged
keep it from saying so. One made on GitHub or GitLab before it merged doesn't, as
that is in what merged.

Removing a worktree and its branch also deletes what Git doesn't count, and
retiring keeps that for 30 days first:

- **A commit only a reflog holds**, as when the agent committed, then ran
  `git reset` back past it to start over. Retiring keeps it by a ref of its
  own; `git log --glob='refs/roost/kept/<id>/*'` shows it, and
  `git branch NAME COMMIT` brings it back. Not the old copies a rebase
  leaves, whose changes the branch has.
- **Ignored files**, such as `.env.local` or a local database. Retiring
  copies them into Roost's state folder, `kept/<id>/worktree` (on the task's host),
  not into Git, so that no push sends them. It leaves out a file the
  primary checkout has the same copy of, as one your setup command copied,
  a folder Git ignores whole, as `node_modules/` or `dist/`, which a setup
  command makes again, and a file past 16 MB, or past 256 MB in all. It
  names what it left out for its size. A worktree the task's agent made
  goes with the task too, and its ignored files go in `kept/<id>/agents`.
  A submodule's ignored files are kept with the worktree's; a commit only
  a submodule's reflog holds is not.

The message after `x` or `m` says what was kept and where. Discarding a task
keeps nothing, and drops what a retire that was then refused had kept: you
chose to lose it.

Once those checks pass, retiring or discarding moves the worktree into the
state folder's `trash/` in one rename, however many files it holds, and
says it's done. The files are deleted afterwards, in the background, on the
task's host. A worktree outside the state folder's file system is removed
by Git as before, which takes longer. A deletion cut short, as by a
reboot, finishes on the next retire, discard or refresh. What can't be
deleted, as files a container made as root, stays in `trash/` under a
name starting `.left-`, for you to delete.

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
`merged`, which goes by its own branch, nor `conflicts` but of a pull
request from `feat`, below. To finish it:

- To merge the work with `m` or `P`, check out the task's branch in the
  worktree and merge `feat` into it.
- `x` discards the task: its worktree, its own branch and its window go,
  and `feat` keeps its commits. It first says what that loses, as files not
  committed, or commits made on a detached HEAD.

Once `feat` is pushed, Roost also looks up pull requests from it, as when
the agent made it to follow a team's naming and opened one, and shows the
one found while the worktree stays on `feat`: in the task panel, under
"Pull request from feat", with its checks and open review threads, in the
dashboard, and in the task's status, `to merge`, `ci failed`, `comments` or
`conflicts`, which notifies as the task's own would. It counts only one
whose head is a commit made on `feat` or the task's branch, and still on
`feat`, so a retired task's or a fork's branch of the same name doesn't. A
commit since GitHub was last asked holds back `to merge` until it is asked
again. The next step names `e` for the agent, or says to merge it on
GitHub: `P` still acts on the task's branch, so it neither pushes to that
pull request nor opens it; its number in the panel opens it. Roost doesn't
record it, so the task's own pull request, `m`, retiring and
`roost-task-merged-functions` stay the task branch's. Once it merged all of
`feat`, the next step says so, and that `x` discards the task, keeping
`feat`, which then loses no commits; the task doesn't say `merged`, which
means its own branch is. When the worktree goes back to the task's branch,
or on to a third, the task's own pull request shows again at once.

### How many agents you keep up with

`w`, or `M-x roost-workload`, shows, for
each of the past seven days, today among them, the most agents that worked at once, how
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

`roost-dashboard` opens the dashboard (`S` in the menu, the sidebar and a
task's panel). These keys work in it and in a task's panel, where `g`
redraws the panel and `q` closes it:

| Key | Command | |
| --- | --- | --- |
| `h`, `?` | `roost-dispatch` | A Magit-style menu of every command below, naming the task they act on and what to do next |
| `RET` | `roost-open-task` | Open the task's agent terminal and workspace; for a stopped or crashed agent, offer to resume it, in the same question as the others that crashed on its host |
| `c` | `roost-new-task` | Draft a new task, from the region or Org entry if any (`C-u` forks the current task, its agent's conversation too) |
| | `roost-copy-attach-command` | Copy the shell command that attaches another terminal, as a phone's SSH app, to the task's agent; while it is attached, the agent's window takes that terminal's size, in Emacs too |
| `C` | `roost-new-conversation` | Open an agent's terminal in no project, with nothing to write first (`C-u` asks which host) |
| `n` | `roost-next-waiting` | Next task waiting for you, permission requests first, saying why it waits; once none does, again goes back to where you started |
| `t` | `roost-shell` | Shell beside the agent, in the worktree (reused) |
| `f` | `roost-files` | Dired in the worktree |
| `r` | `roost-review` | Magit in the worktree, showing what changed since you last looked |
| `D` | `roost-diff` | Diff the task's own changes, including uncommitted ones; with no new file left out, that counts as looking at it |
| `v` | `roost-mark-looked` | Record that you've looked at the task as it stands now, opening nothing, so what changed since you looked starts from here |
| `e` | `roost-send` | Paste a prompt into the agent and press Enter |
| `i` | `roost-task-info` | The task's next step, prompt, your latest prompt, changes, checks, open review threads, the agent's latest reply and details |
| `R` | `roost-rename` | Rename the task, in Roost, its tab or perspective, and its agent's tmux window; its branch and worktree keep the name it started with |
| `B` | `roost-retarget` | Change the branch the task starts from and merges into, as after you rebased its branch onto another: `m`, `u` and its counts follow; no commit moves, and a pull request already open keeps its base |
| `L` | `roost-leave-pull-request` | Leave the task's pull request to its agent, or take it back: left, Roost tells the agent itself when a check fails, a review thread waits or it conflicts, once for each ([below](#a-pull-request-left-to-its-agent)) |
| `l` | `roost-switch-task` | Choose a task by name, waiting tasks first |
| `/` | `roost-search` | Find messages in your tasks' conversations, retired tasks' too; `RET` opens a live task, `TAB` shows more of a message (its first 1,500 characters), `n` and `p` move between messages, and `g` searches again. Each host reads the conversations Claude Code, Codex and Pi keep there, and each message names its agent; OpenCode's are not searched, and a host with an OpenCode task says so |
| `b` | `roost-sidebar-mode` | Keep the task list at the left of the frame |
| `I` | `roost-task-panel-mode` | Dock the open task's panel beside its terminal |
| `u` | `roost-update` | Bring the task up to date: merge the branch it merges into, such as `main`, into it; for uncommitted changes or conflicts, offers to have its agent do it |
| `P` | `roost-pr` | Draft a pull request for the task; if it has one, push new commits and open it (`C-u`: open only); after one closed, or merged with commits since, draft another |
| `m` | `roost-merge-retire` | Merge committed work as one commit, then retire the task (a merge commit with `roost-merge-style` set to `merge`) |
| `x` | `roost-retire` | Finish with a task: retire it when its work is merged or it has none, otherwise offer to discard it (`roost-discard`), first saying what would be lost; to lose commits or files you type its name. An agent with work left in the background is stopped first, once you say so; one in the middle of a turn is refused, and `K` stops it |
| `X` | `roost-forget` | Drop the task from Roost, leaving its worktree and branch as they are |
| `K` | `roost-stop` | Stop the agent's window, and what it left running; keep all work |
| `s` | `roost-resume` | Restart a stopped, exited or crashed task in its recorded conversation; when other agents crashed on its host too, as after it restarted, ask whether to resume those as well. Refuses while the agent runs in the task's shell or another window of its tmux session, which Roost didn't start |
| `w` | `roost-workload` | How long agents worked and waited on you, each day of the past week ([below](#how-many-agents-you-keep-up-with)) |
| `=` | `roost-compare-attempts` | For a task a draft made with others from one prompt (`C-c C-x` there): list every file any of those attempts changed, with a column for each attempt saying what it did to the file |
| `g` | `roost-refresh` | Refresh status and Git statistics |
| `!` (in the menu) | `roost-doctor` | Check the setup of this machine and each host |

Where attempts are compared (`=`), each attempt has a line with its number,
status and changes, and each file a line with `+12 −3`, `new` or `binary`
under the attempts that changed it and `·` under those that left it alone:

| Key | Command | |
| --- | --- | --- |
| `RET` | `roost-attempts-visit` | On a file, compare two attempts' copies of it in Ediff, each in its own worktree: the two that changed it, or of more, the two you choose. A file only one attempt changed opens there. On an attempt, open it |
| `m` | `roost-attempts-merge` | Merge the attempt at point and retire it, as `m` does for any task; elsewhere, ask which. The others stay until you finish them, as with `x` on each: Roost deletes work only when you discard a task |
| `g` | `roost-attempts-refresh` | Redraw, and ask the host for each attempt's changes as they are now |
| `h`, `?` | `roost-dispatch` | The menu, for the attempt at point |

On an offer an agent made, listed under its task in the dashboard and
sidebar: `RET` (`roost-open-offer`) opens it as a new task draft, `e`
(`roost-offer-here`) has that agent do it there, and `x`
(`roost-offer-dismiss`) dismisses it; `mouse-3` offers all three. In its
draft, the **Dismiss offer** button (`roost-compose-dismiss-offer`) dismisses
it and closes the draft. The other
keys act on the task it sits under.

`j`/`k`, or `TAB` and `S-TAB`, move between tasks; `mouse-1` opens one and `mouse-3` shows its actions.
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
asks GitHub about the pull requests of tasks whose branch was pushed, or the
branch their worktree is on, with one `gh api graphql` query per repository
for review threads and where they are, or GitLab, with one `glab api graphql`
query per branch.
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

In a prompt draft (`e` or `@`): `C-c C-c` sends, and what you write as it goes
stays there; asked again after no reply, it goes once. `C-c C-k` cancels,
`C-c C-a` attaches a file from this machine (or the Send, Cancel and Attach
buttons in its header line) and `C-c C-v` the image on the clipboard (as does
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
name. `C-c C-t` starts from a GitHub or GitLab issue (with `gh` or `glab` on
the project's host) or a Jira work item (with `twg` on this machine). An empty name is derived
from the prompt; `R` renames the task later.

`C-c C-x` sets how many attempts the draft makes at its prompt, which its
Attempts line shows: a number from 1 to 5, each by the draft's agent, or
agents' names with spaces between, as `claude codex`, one by each. `C-c C-c`
then creates a task for each at once, from the same prompt, project and
starting ref. The first has the draft's name and opens, as one task does;
the others have that name with 2, 3 and so on after it, and start without
taking you anywhere. Asked again after no reply, each is made once. If you
changed the draft before asking again, and its host had made one of them
from what it said before, none is made from what it says now beside that
one: the draft stays, saying which task was made from what you sent before,
and `C-c C-c` then makes every attempt from what it says now. One of
the others that fails says so in the echo area, and the rest go on. They
are tasks like any other, kept together in the dashboard and sidebar, and
`=` on one [compares them](#commands).

`C-u c` on a task drafts a fork of it, so you can take the work another way
and keep whichever goes better. Once the task's agent has a conversation,
the fork goes on with it: its agent starts from a copy of that
conversation, as Claude's `--fork-session`, `codex fork`, Pi's `--fork` and
OpenCode's `--fork` make one, and its worktree has the task's uncommitted
changes as well as its commits, unstaged as they were, since the
conversation expects them. Ignored files, and untracked ones too large for
"since you last looked" to keep, stay behind. The task's own conversation
and work go on as before. Your prompt is the fork's first message, after a
sentence Roost puts before it, telling the agent it now works in a new
worktree and should leave the task's alone: its conversation names the
task's worktree, which the agent would otherwise look in too. The
draft's Context line says which conversation the fork has, and `C-c C-f`
trades it for a new one, a fork of the task's commits alone. Only the
task's agent can go on with its conversation, so choosing another agent
starts a new one too.

Emacs waits up to eleven minutes for a new task's worktree, which a
repository with gigabytes of Git LFS files can take that long to check
out. With no reply by then, the draft stays and says so, and the task opens
if the host made it. `C-c C-c` there asks again for the same task: the host
answers with the one it made, or makes it, never a second. If what the draft
says by then isn't what that task was made from, the draft stays as you left
it and says so, and `C-c C-c` makes another. A creation cut short, as when
Emacs stops one on this machine, leaves no worktree or branch behind.

The new task opens if you are still where you created it. If you have gone to
another buffer, window or task by then, you stay there: the echo area says it
was made, and `RET` on it in the sidebar or dashboard opens it.

`C-c C-p` lists the projects Roost has used, the last first, then those
`project.el` knows. "Other directory…", second in the list, asks for a host,
of those Roost knows or another from `~/.ssh/config`, starting on the draft's,
and then for a folder there, starting above the project used last on that
host, or at its home. With only one host known, it asks for the folder. The
folder is reached with TRAMP's method for the host, such as tramp-rpc's when
`tramp-default-method` is `"rpc"`, and typing a whole TRAMP path works too.

A task's integration branch is the one `m` merges it into, `u` updates it
from, `P` opens its pull request against, and `↑`/`↓` count from. It is the
branch the task starts from, and the draft says so next to the starting ref
("merges into release"). A remote-tracking branch, such as `origin/main`,
gives the local branch of its name, which Roost makes to track it if there
isn't one, as `git switch` would. A task's branch, as when you fork one with
`C-u c`, gives that task's integration branch. With no starting ref, or a
tag or commit, it is the branch the primary checkout has checked out. `B`
changes it later, by the same rules, for a task started from the wrong
branch.

In the pull request draft: `C-c C-c` creates the pull request (`C-u` as a draft)
and `C-c C-k` cancels, as do the Create, Create draft and Cancel buttons in its
header line. A failed creation keeps the draft.

## Configuration

- `roost-hosts`: hosts the dashboard watches (`nil` is local). Hosts and projects
  you create tasks in are remembered in `roost-hosts-file` and `roost-projects-file`;
  `M-x roost-forget-host` stops watching one you no longer use, and closes
  its tasks' terminals and panels; their agents keep running.
  `M-x roost-forget-project` takes a project out of the sidebar; drafts offer
  it still while one of its tasks is listed or project.el knows it.
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
- Submodules: `git worktree add` leaves their folders empty, so Roost checks
  out a new task's submodules, nested ones too, at the commits its branch
  records (`git submodule update --init --recursive`, with Git 2.24.1 or
  newer, which won't run a command a branch's `.gitmodules` names), in the
  task's terminal, where SSH can ask for a passphrase, before the copy and
  the setup command. It checks out the ones the primary checkout has
  initialized, so `git submodule deinit` there leaves one out, or all of
  them where it has initialized none; `git config submodule.NAME.active
  false` leaves one out either way. Roost doesn't initialize the others, as
  `--init` alone would, in the config the primary checkout shares. If one
  can't be checked out, the task stops before its agent starts and says
  which; `s` tries again and starts it. Each task fetches them into clones
  of its own. To change one in a task, commit on a branch in it and push
  that, then commit the submodule in the task: merging and retiring refuse
  while a submodule holds commits its remote lacks. After a merge, `git
  submodule update` in the primary checkout checks out what the task
  recorded.
- `roost-setup-command`: a shell command run once in a new worktree before the
  agent starts, such as `npm ci`. Set it in `.dir-locals.el` per project:
  `((nil . ((roost-setup-command . "npm ci"))))`. Emacs reads a remote
  project's `.dir-locals.el` only with `enable-remote-dir-locals` on. It runs
  once Roost has checked out the submodules and copied what
  `.worktreeinclude` lists, and finds the primary checkout in `$ROOST_REPO`,
  for anything else it needs from there.
- `roost-ready-worktrees`, on by default: after a task starts, its host makes
  another worktree of the project in the background, detached, under the state
  folder's `ready/`. The next task there takes it, moving it into place and
  checking out only the files that changed since, rather than every file: in a
  37,000-file project, the reply comes in under half a second rather than 2.8 s. The
  repository's `post-checkout` hook runs as it would for a new worktree. It
  costs one more checkout of each project you start tasks in, which `git
  worktree list` shows; one not taken in a week goes. Set it to `nil` in
  `.dir-locals.el` for a project too large to keep twice, and the next task
  there removes it.
- `roost-teardown-command`: a shell command run in a task's worktree just before
  Roost removes it, when you merge, retire or discard the task, set the same
  way. It cleans up what a tool keeps for the worktree elsewhere, such as
  Bazel's output base and server:
  `ob=$(bazel info output_base) && bazel shutdown && chmod -R u+w "$ob" && rm -rf "$ob"`.
  It runs on the task's host with the primary checkout in `$ROOST_REPO`, and
  is stopped after two minutes; to take longer, it can leave work outside the
  worktree running in the background (`rm -rf "$ob" &`). If it fails, Roost
  warns, with what it printed, and removes the worktree anyway. A file it
  leaves in the worktree keeps the task from retiring, as yours would, and
  Roost names it: have the command clean up after itself, or ignore what it
  leaves (in `.gitignore`, or the primary checkout's `.git/info/exclude`), as it runs again each time
  you retire.
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
- `roost-decorate` (t): draw the views with more than their text: a tint
  behind a status that wants you, a band behind what is wrong with a task,
  a hairline under each heading, line counts in a column, a little air
  between a list's rows, and a status light in the shape of its status
  (a disc in a ring asks, a disc finished, a triangle failed, most of a
  ring is at work, a ring of dots is starting, two bars stopped, a tick
  merged, a dash is a host out of reach, a small dot waits for nothing).
  The colours are made from your theme's, and no text differs; nil draws
  the same words without any of it, each light a dot.
- `roost-leave-pull-requests` (nil): leave each new task's pull request to
  its agent, as [`L`](#a-pull-request-left-to-its-agent) does for one task.
  For tasks started after you turn it on.
- `roost-remote-control` (nil): start each Claude Code task with Remote
  Control (`--remote-control`, `--name`), named for the task, so it shows
  in the Claude app and at claude.ai/code, which notify your phone when
  its agent needs a decision. Needs a Claude subscription. For tasks
  started after you turn it on.
- `roost-agent-offers` (t): let a task's agent offer tasks of their own,
  which wait under its task for you to take
  ([Take the tasks an agent offers](#a-day-with-roost)), and a
  conversation's agent offer tasks in your projects, and either show you
  an image beside its terminal. For every agent. Nil
  gives agents no tools of Roost's, for tasks started after you change it.
- `roost-agent-pages` (nil): with `roost-agent-offers`, let a task's agent
  show you a page it writes, such as a diagram you can click
  ([See a page an agent writes](#a-day-with-roost)). Off by default: its
  tool adds to each request the agent makes, and a page shows only in a
  graphical Emacs built with xwidgets. For tasks started after you turn it
  on.
- `roost-large-change` (`(:lines 400 :files 10 :directories 3)`): when a
  task's row gets its `±`. Leave one out to mark by the others, as
  `(:lines 400)`; nil marks none
  ([How large a change is](#how-large-a-change-is)).
- `roost-notes-file`: review notes not yet sent, kept across sessions.
  Faces `roost-note` and `roost-note-button` color the notes and the `+`.
  Two Emacs on one machine can share this file, `roost-hosts-file` and
  `roost-projects-file`: what one writes stays, and the other takes it up
  when it next writes to the file, or starts.
- `roost-magit-status-sections` (t): whether Magit's status of a task's
  worktree names the task and folds in its agent's latest reply.
- `roost-branch-prefix`: topic branches are `PREFIX<name>-<id>`; default `roost/`.
- `roost-jira-query`: the JQL for the Jira work items `C-c C-t` lists, by
  default your open ones,
  `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`;
  nil lists none. Set it directory-locally for a project's own backlog, as
  `project = PROJ AND statusCategory != Done ORDER BY rank`.
- `roost-state-directory`: where each host keeps task records, the helper and
  worktrees; default `~/.local/share/roost`.
- `roost-socket-name`: the tmux socket (default `main`). Each task has a
  session of its own, named after its project and task.
- `roost-sidebar-width` (30), `roost-task-panel-width` (44): the sidebar and
  the panel docked beside a task's terminal. Drag either's edge to change it
  for every task, until Emacs exits; a task's workspace doesn't keep its own.
- `roost-sidebar-recent-projects` (3): how many projects with no tasks the
  sidebar lists on each host for a new task; 0 lists none, nor "Other
  directory…".
- `roost-workspace`, `roost-compact-mode-line`: how tasks get their own windows
  (see above); with perspective.el, task perspectives share one
  `Roost: host/task +N` entry in the perspective bar, and a click on it shows
  the tasks in a menu. In a workspace that is no task's, such as the one a
  frame made with `C-x 5 2` starts in, the panel and the sidebar follow the
  task whose terminal it shows, and show only while it shows one.
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
- `roost-task-opened-functions`: your own functions to run once Roost has
  shown a task's terminal, as `RET`, `n`, `l` and a new task do, called
  with the task in the terminal's window. For what a setup of yours does
  on arriving in a terminal, such as a modal one entering its insert
  state:

  ```elisp
  (add-hook 'roost-task-opened-functions
            (lambda (_task) (my-enter-insert-state)))
  ```

  The terminal may still be connecting, and the buffer shown then stands
  in for it.
- `roost-task-status-functions`, `roost-task-merged-functions`: your own
  functions to run when a task's status changes, or once its work is merged.
  Each status function is called with the task, its status before and its
  status now, as the host records them: `starting`, `running`, `ready` (its
  turn is over), `permission`, `failed`, `crashed`, `exited` or `stopped`,
  and, as Roost lets the task go, `retired`, `discarded` or `forgotten`.
  They run for changes this Emacs sees, not when Roost first sees a task.
  Each merged function is called with the task and the branch its work went
  into, when `m` merges it or when Roost sees GitHub or GitLab merge its pull
  request. Roost asks about the branch's latest commit, so a pull request
  merged and followed by new commits before Roost next asks goes unreported.
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
- `roost-watch-interval` (3 s): how often Roost asks its hosts while Emacs
  is in front.
- `roost-ssh-share-connections` (t): each poll is one SSH command per host,
  and Roost shares one connection per host across them (OpenSSH
  `ControlMaster`, with its socket in the state directory, closed a minute
  after the last request), so polls skip the handshake; nil leaves that to
  your ssh configuration. Unreachable hosts are retried with backoff and
  keep their last known tasks, marked unreachable.

A few variables tune Roost without being options, and may change between
releases; set them with `setq`. `roost-watch-unfocused-interval` (15 s)
is how often Roost refreshes while no Emacs frame has focus,
`roost-request-timeout` (60 s) how long a host operation may take,
`roost-startup-grace` (15 s) how long a task starts before Roost takes it
to wait at a prompt, and `roost-note-box-lines` (4) how many lines the box
for writing a note shows.

### A task's terminal

Roost shows a task's tmux session with
[ghostel-tmux](https://github.com/dakra/ghostel-tmux), which draws it with
[Ghostel](https://github.com/dakra/ghostel). It needs Ghostel 0.65.0 and
ghostel-tmux 0.4.0 or newer; `M-x roost-doctor` checks both.

- A terminal's keys are ghostel-tmux's: tmux's own, after `C-t`, such as
  `C-t o` for the next pane.
- A task's terminal is named in its mode line by its host and task, as
  `dev › budget-alerts`; its buffer's name spells out the tmux session and
  pane.
- A host is reached through TRAMP. Before the first terminal on a host,
  Roost asks the host by `ssh` where its tmux is and turns on TRAMP's
  direct async processes for it if the host takes a command that long
  (Linux does; macOS does not). Without them a terminal on a host takes
  three times as long to open, and Roost can stall. TRAMP keeps both
  settings for the host, not for Roost, so they hold for whatever else
  you do there through TRAMP in this Emacs. Roost leaves one you set for
  the host yourself: to keep TRAMP's own processes on a host, give it a
  connection-local `tramp-direct-async-process` of nil.
- When the connection to a host drops, the terminal attaches again by
  itself once the host answers, trying for about two and a half minutes;
  after that, opening the task attaches it.
- Until a session's pane arrives, its window says "Connecting to" the
  session. If it cannot be attached, as when the session ended while you
  opened its task, the window says "Could not attach to" it: `q` goes
  back to what the window showed, and opening the task again tries once
  more.
- A tmux window of several panes, as a task's with a shell beside its
  agent, shows as a split. Magit, a diff or a file you open from one of
  its panes shows beside the split, not in it. A pane made narrower can
  show a line or two above what tmux has on its screen, until its program
  draws again.
- Over a slow connection, a split of panes can come back in a window you
  have since put another buffer in, when tmux's word of its layout
  arrives late. Roost opens what you asked for all the same.
- A host that runs macOS is untried. Emacs 30.2 on macOS can crash when a
  task is stopped after its connection dropped, a fault of that Emacs
  which later ones do not have.

#### Images in a terminal

Ghostel draws the images a program sends in the Kitty graphics protocol,
from this machine or a host, when the program sends the picture itself
rather than naming a file. tmux does not answer a program that asks
whether its terminal draws them, so an agent has to be told:

- **Pi** sends the images its tools read. Roost starts it with
  `PI_IMAGE_PROTOCOL=kitty` in its environment, which Pi 1.3.0 and 1.5.2
  read, when a task starts or resumes; one you set yourself stands.
- **Claude Code, Codex and OpenCode** send no images to their terminal.

A task of any of the four can show you an image beside its terminal
instead, with Roost's `show_image` tool
([See an image an agent shows](#a-day-with-roost)), which stays when the
agent draws its screen again.

`clear` leaves an image on the screen; a program that clears the whole
screen removes it. With Pi 1.5.2, an image goes blank when Pi draws its
screen again, as after its window changes size or you fold its thinking;
it draws again when Pi next reads the file.

Claude Code's `CLAUDE_CODE_FORCE_TERMINAL_IMAGES` does not change this:
with it set, Claude Code 2.1.325 wrote no image to its terminal for a file
it read, or for one attached to a prompt. Nor does tmux's
`allow-passthrough`. Going by its code, which was read and not run, that
version draws only a plugin's own pictures and its mascot on a file
transfer, and the variable is for those: in tmux it otherwise draws them
only when tmux names kitty, Ghostty or iTerm2 as the terminal outside it,
which tmux cannot do for Emacs. Drawing the files it reads is asked for in
[claude-code#79706](https://github.com/anthropics/claude-code/issues/79706).

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
[State machines](state-machines.md) has every state Roost keeps, what must hold
of it and each way between them.

The helper notes each change of a task's status, of whether you've seen its
agent since its last event, and of what of its pull request or work waits on
you, in a file a day under `history` in its state directory, and deletes
files older than 30 days. Only Emacs asks GitHub, so it tells the helper when
a task's pull request or conflicts come to wait on you, or stop.

A task's identity is its host and ID. A per-pane ownership tag keeps Roost from
steering or killing an unrelated pane after a tmux restart, and hooks from an
earlier run cannot overwrite a resumed one. The tag goes with the pane, so a
pane you move in tmux is still the agent's, wherever it is; what you start in
it with `respawn-pane` is not. Stopping a task closes the agent's pane and its
shell, and their window if nothing else is in it: a pane of your own stays.
What the agent or that shell left running, as a server started with `nohup`,
stops too, so that nothing writes into the worktree as retiring removes it,
but for a daemon, such as a build tool's server, which other tasks may share.
What won't stop, as another user's process, is named, and keeps the task from
being retired or discarded until you end it.
Merging needs the task's worktree
clean. With the primary checkout on the task's integration branch, the merge
happens there and needs nothing uncommitted (untracked files stay); with it on
another branch, Git merges into the integration branch without touching your
checkout (Git 2.38 or newer). A merge that conflicts leaves nothing changed.
One that a commit hook in the primary checkout refuses is undone, leaving
what the hook changed in other files. While a merge or `u` runs, agents and
polls go on, but commands on that task say it is under way, and so does a
second merge in that repository. It goes on to its end if Emacs stops waiting,
as anything that changes a task does, on this machine as over SSH. Stopped
partway, as by a reboot, it says what it left and how to undo it, as `git
reset --merge`. Nor does Roost change anything when it
refuses, saying what to do first: to merge a task whose worktree is locked,
was moved, or is in the middle of a rebase, cherry-pick, revert or bisect,
or into a branch whose rebase is under way. Neither a merge nor `u` writes
over or deletes a file Git ignores in the checkout it merges in, such as
your `.env`, as Git itself would without asking: Roost names it, for you to
move aside.
Branches are deleted only if they still point at the commit Roost verified.
Removing a worktree deletes the repositories of its submodules, which may
hold the only copy of commits made in them. Retiring removes one only when
they hold nothing their remotes lack, as when Roost checked them out for the
task; otherwise it says which submodule holds what, for you to push.
Discarding counts those commits among what it would lose.

Things to know:

- Claude Code and Codex run no hook when you answer a permission request, so
  Roost looks for itself. A Claude Code command you approve shows `running` at
  the next poll, once Roost sees it start; declined, or stopped with Esc, the
  task shows `interrupted`, read from its transcript. Codex's hooks say when
  you decline or press Esc. Claude Code's other tools, and Codex, may keep
  showing `permission` until the agent moves on, and `e` asks before sending
  to a task in that state. What a subagent does beside one that asks doesn't
  count as moving on. A Claude Code subagent that asks from the background
  keeps the task at `permission` after the main agent's turn ends, until
  that subagent goes on or ends, or you send a prompt; with several asking
  at once, one of them a subagent, until a turn ends with nothing left in
  the background, or you send a prompt. With
  `roost-program-status` on, both say so themselves, at once.
- In Plan mode, Codex ends its turn with a plan and then asks, in a menu,
  whether to implement it. Text sent to it then would be dropped, and the
  Enter after it would implement the plan, so the task shows `permission`
  ("Asks whether to implement its plan"), its latest reply is the plan, and
  `e` asks before sending. Codex says nothing when you close the menu, with
  Esc or "No, stay in Plan mode", so the task shows `permission` until your
  next prompt: answer `e`'s question with yes. Retiring and merging go
  ahead meanwhile, as its turn is over.
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
  once you allow the host, until the command ends. An MCP server's question
  shows the same way, until you answer it.
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
  one holds work not on the task's branch. Finishing the task removes them, with
  the branch Claude made for each. A worktree its agent only went to, one that
  was there before the task, and a folder that is no longer a worktree stay,
  as does a branch of yours its agent switched to there, and Roost says what it
  left in place. So does a `/batch` worktree: its folder names no agent, so
  Roost can't tell it from another session's, doesn't list it or check it
  before merging, and leaves it for you to remove.
- Claude Code writes a conversation once something is said in it, so a task
  stopped before that has none to go back to: `s` starts it anew, with its
  prompt if it has one.
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
  So does a Jira work item's description and rich-text fields, which anyone
  who can file or edit one in your site wrote.
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
- The helper runs `git`, `tmux`, `gh`, `glab` and the agent with each argument
  separate, not through a shell. The command lines that tmux and Claude
  Code and Codex hooks hand to a shell, to start an agent's runner and to
  report its events, are quoted with Python's `shlex.join` and hold only
  Python, Roost's files in the state directory and the task's IDs. The
  other shell commands are your `roost-setup-command` and
  `roost-teardown-command`.
- With `roost-agent-offers` on, the task's agent starts the helper as an
  MCP server of its own, over its standard input and output, and ends it
  with itself. Each is told of it for that one launch: Claude Code by
  `--mcp-config`, Codex by `-c mcp_servers.roost_task…` overrides, OpenCode in
  the inline config Roost already sets, and Pi by Roost's extension, which
  registers it for the session. Each runs its tools without asking: Claude
  Code by an allow rule in the task's settings file, Codex by the server's
  `default_tools_approval_mode`, OpenCode by a rule Roost's plugin adds
  after yours, and Pi asks about no tool unless an extension of yours does.
  Nothing is written to `~/.claude`, `~/.codex`, `~/.config/opencode` or
  `~/.pi`. Its tool `show_image` copies an image file the
  agent names into Roost's state directory, if its first bytes say it is a
  PNG, JPEG, GIF or WebP and it is at most 8 MB, and notes it in the task's
  record; Emacs draws that copy and nothing else. It copies up to six
  together, of 16 MB in all, each checked the same way. With `roost-agent-pages`
  on, its tool `show_widget` keeps a page the agent writes the same way.
  None of the agent's code is in the page Emacs loads: it is the text of a
  frame with no origin of its own, allowed to run scripts and nothing
  more, under a policy that lets scripts, styles and fonts load from
  cdnjs.cloudflare.com, cdn.jsdelivr.net, unpkg.com, esm.sh and Google
  Fonts, and nothing else load or be sent. So a page cannot open a window,
  send a form, or take itself or the page around it to another address;
  what it asks to send you goes into a draft to the task, which you send.
  A page shown while it is written is handed to that same frame as markup,
  so it can do no more than a whole page; its scripts wait until it is whole.
  `show_image` can name any file
  the helper can read, so an agent learns whether a path is such an image,
  and no more: every refusal reads the same. Its tool `propose_task` writes an offer
  into the record of the task whose agent called it, and nothing else, and
  `list_projects` names the projects that host has run tasks in: none of
  the three runs a program or reaches another task. The task's own Claude
  settings allow them without asking. An offer may name another project,
  by the folder of a Git repository there, which you read in its draft; a
  conversation's must, and its Claude settings also let it read, and only
  read, the files of the projects `list_projects` names without asking. An offer's title and brief can
  hold no control character, nor one that doesn't show as itself, and you
  read both in the draft before anything starts from them; Do it here
  sends only a fixed line with the title.
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
- Roost won't paste text holding a control character, other than a line
  or page break or a tab, as the agent's terminal would take it as a key.
  It says which and on what line, and sends nothing. The same goes for a
  byte that isn't text, from a file that isn't UTF-8, which shows as
  `\351` in Emacs. A review note quotes such a line as Emacs shows it.

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
  fetch and push a task's branch for its pull request, to fetch a commit
  made on GitHub or GitLab that a pull request's head is, in the project's
  primary checkout, once for each such commit, to delete that
  branch once it is merged, and in `roost-doctor` to try a push with
  `--dry-run`; `gh` on a host, or `glab` for a project on GitLab, for
  issues, pull requests, their checks and comments; and `twg` on this machine, when it is installed, for the
  Jira work items a draft can start from, as you press `C-c C-t`. It sends
  nothing anywhere else: no telemetry and no update checks. Agents reach their own services as they would without Roost.
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

Dependencies: Emacs 29.1 or newer, transient, ghostel-tmux and the Ghostel
terminal it uses, and on each host tmux, Git and Python 3.9 or newer. The helper is one file of
Python's standard library.

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
without model calls), and a warning-free byte-compile. `make test` uses every
core, each Emacs and Python taking a share (`test/run.py`): about four minutes
on four cores, where one process takes eighteen. While you work, `make quick`
runs one case in twelve of each sweep, and leaves out a suite, ERT or
Python, that passed in full on what it reads now: half a
minute after a change to `roost.el` alone. `make quick K=REGEXP` runs only the
tests that match. CI runs it on Emacs 29.1
and 30.1, except for a change only to Markdown files or `docs/`, which no test
reads: then its checks pass without running it. The tests of Roost in Magit need Magit and its dependencies on the
load path, as `make test TEST_LOAD_PATH="-L …/magit/lisp -L …"`, Evil
and evil-collection for its Evil keys there, and perspective.el for the tests
of task perspectives in it; without them they are skipped.

The helper times each step of starting and finishing a task, and keeps the
times for 30 days in the state directory's `timings/`, a file a day.
`make timings` shows how long each step took for the last 20 tasks on
this machine, slowest first, with `TASKS=N` for another number and
`ROOST_STATE=DIR` for another state directory. On an SSH host, run the
newest helper Roost installed there:

```sh
ssh HOST 'python3 "$(ls -t ~/.local/share/roost/remote-*.py | head -1)" timings ~/.local/share/roost'
```

A step is named for the
request, `create`, `resume`, `retire`, `merge` or `discard`, then what it
timed:

- `reply`: the whole request, which is how long Emacs waits.
- `prepare`, `worktree`, `carry` and `spawn`: reading the repository, `git
  worktree add` with its checkout and hooks, bringing a fork's uncommitted
  changes, and opening the terminal.
- `submodules`, `copy` and `setup`, in the task's terminal: checking out
  submodules, copying `.worktreeinclude` files, and the setup command.
- `agent`: from launching the agent to its first status other than
  starting; `total`, from asking for a task until then.
- `forge`, `checks`, `merge`, `stop`, `recount`, `teardown`, `keep`,
  `remove` and `branch`: asking the forge whether a pull request merged,
  the checks before anything is deleted (and a merge's own time), merging,
  stopping the agent, a discard's count again once it has stopped, the
  teardown command, keeping what removing would delete, removing the
  worktrees and deleting the branch.

A step that fails, or doesn't run, isn't noted.

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
  or nothing changes it back; for an image, several images or a page an
  agent showed beside its terminal, the frame's windows count as the view,
  so one that fills the frame must have a way back to them;
- an image or page that takes a window of yours with it when its task goes
  or you kill its buffer, as it came or after any key or click in it;
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

`make crash` kills the host helper partway through each action, as a dropped
connection or a reboot would: at every Git and tmux command it runs, before
the command, after it, or leaving it running, and at every hook Git runs,
with Git dying too; and fails each command that changes something, as a full
disk would, as `test/crash_harness.py` says. After each, it does what you
would: looks at the list, asks again, and discards what is left. It fails on
work lost, a task or worktree that can't be got rid of, a merge done twice or
left under way, or a refusal that doesn't say what to do. It is slow, so
`make test` leaves it out; `make crash CRASH_SWEEP=lines` also kills the helper
at each line it reaches, which is slower still. `test/test_crash.py` keeps the
crashes that went wrong for `make test`.
Emacs talks to each host asynchronously, and the sweep above answers at once.
`test/roost-sweep-late.el` holds the reply to each command back, does what you
might do meanwhile, then delivers it good, refused in the host's words, dropped
by the connection, or timed out, as a process sentinel would. What you might do
is kill the buffer the command started from or the task's terminal, delete its
window or frame, go to another buffer, window or task, start another action on
the task, have the task go through another reply or a poll, have a newer poll
come first, forget the host, quit, leave a question open in the minibuffer, or
turn watching or the side windows off. Then it fails on:

- a Lisp error, in a reply or a timer, where Emacs would only log it;
- a reply that writes into a buffer that isn't its own;
- the selected window, its buffer or the task opened last moving, unless the
  command was to open something and you stayed;
- a reply that overwrites what is newer, or brings back a task that went or a
  host you forgot;
- something left busy or waiting: a draft that says it is sending, a host that
  counts as being refreshed, a hook, a timer;
- a row in a view that offers a task that went;
- a question landing in a minibuffer you are typing in, or one about a task
  that went;
- the failure of a command you gave not said in words, once.

Windows, buffers, timers and minibuffers are real, and a held reply says what
its host knew when it was asked; `roost--run` is stubbed. A terminal is
tmux-control's, stubbed to show at once, except for the commands that open a
task with `:backend ghostel-tmux`: those run `roost-ghostel-tmux.el` on a
ghostel-tmux stubbed at its public functions, and hold back the session's
pane, which then comes, or whose tmux client ends first. One test takes each
way a reply can end through a real process, and another unloads Roost with
requests under way, in an Emacs of its own. Each rule has a way to break Roost
that it must catch, in `roost-sweep-late--breakages`. A new command that
waits on a host needs an entry in `roost-sweep-late--commands`, and a new
question in the minibuffer one in `roost-sweep-late--questions`.

`make qa` uses Roost as you would, in a GUI Emacs of its own: a plain
configuration with its own server, state directory, tmux socket and home
directory, so your tmux, shell and Git configuration don't change it.
`test/fake_claude.py` stands in for Claude Code, so Git, tmux and the host
helper are real and no model is called; `test/qa/fake_gh.py`,
`fake_glab.py` and `fake_twg.py` stand in for `gh`, `glab` and `twg`, with
what each journey has GitHub, GitLab and Jira say.

Its journeys, the functions of `test/qa/qa.py`, go through what you do in a
day: start a task from the menu, an Org heading, an error, a file or an
issue, answer the agent in its terminal, go through the waiting tasks with
`n`, review in Magit and send notes, merge, follow a pull request to its
merge, stop, resume, retire, discard and forget, restart Emacs with agents
at work, and lose a host. One leaves something unfinished, as you do
(`M-x` or Roost's own question open, its menu, a draft, a task whose host
hasn't replied yet, a mouse press in a terminal that never let go, a review
note half written, the question before discarding a task), and then goes
to a task another way: a click, `l`, `n` or `t` in the sidebar, a click on
a notification, or a click in the terminal. They press keys and click
through Emacs's command loop. A menu or dialog of the system's own, which a
right click or a question after a click opens, would hold Emacs up, so the
journey says beforehand what you would choose in it.

After each step it checks for Lisp errors, in commands, timers and process
filters alike, for a backtrace, for lines of Roost's views cut off at the
window's edge, for another task's terminal beside the current task's, for
a terminal that shows other than what tmux has in its pane, or history
nobody scrolled it to, and for a question open in the minibuffer that you
aren't in, unless the journey left it so, or anything Roost holds back
until such a question is done. A key sequence or click that has Emacs
collect garbage more than 20 times fails its step too. It also runs the
sweep where text is measured in pixels.

A run takes about 25 minutes, writes `report.html` with each step's
windows, the echo area and a screenshot, and fails if anything was wrong.
The report ends with the commands of Roost that no journey ran: where the
next journeys should go. A problem known to come from elsewhere, such as a
bug in a package awaiting its release, is marked `Known` in its journey: it
is reported, without failing the run, until it stops happening. Look at
the screenshots too: the checks don't see what merely looks wrong. Emacs
needs Ghostel, with its native module, ghostel-tmux and Magit:

    make qa QA_FLAGS="-L ../ghostel/lisp -L ../ghostel-tmux --package-dir ~/.emacs.d/elpa"

Each step is captured as a screenshot on macOS and under X. On a machine
with no display, such as a container or CI, Xvfb gives it one:

    Xvfb :99 -screen 0 1760x1000x24 &
    DISPLAY=:99 make qa QA_FLAGS="-L ../ghostel/lisp -L ../ghostel-tmux answer offer"

`make gallery`, with the same display, needs no agent, tmux or host: it draws
the task panel and the dashboard for every task state of the sweep's gallery,
a few to a sheet, in seconds, and captures each sheet in `gallery/`. Use it to
see what a change to a view looks like in every state at once;
`GALLERY_THEME=modus-operandi` draws it in that theme.

Package directories are read, never written. `--load FILE` in `QA_FLAGS` loads
Emacs Lisp after Roost, such as a change to try, and `--keep` leaves the Emacs
and its tmux server running. A new flow gets a journey in `test/qa/qa.py`.
Name journeys after the options, as `test/qa/qa.py` names their functions,
to take only those:

    make qa QA_FLAGS="-L ../ghostel/lisp -L ../ghostel-tmux --package-dir ~/.emacs.d/elpa merge walk_away"

Three options take the same journeys elsewhere. `--remote` puts the tasks on
`qa-remote`, a host reached over SSH as yours are: `test/qa/fake_ssh.py` stands
in for `ssh` and runs each command here, with its own home, delaying what goes
each way by `--latency` seconds (0.15 by default). Roost's requests,
the terminals' connections and TRAMP all go through it, so replies arrive as
late as a remote host's do, which is where races between them show. Magit's
review is left out there: over TRAMP's `ssh` method it takes most of a minute.
`--tuned` gives Emacs settings many configurations have: pixel scrolling, a
1 GB garbage collection threshold.
`--popular` adds packages many configurations have, from `-L` or
`--package-dir`: vertico in vertico-posframe's popup, which hides a question
you click away from, recursive minibuffers, and perspective.el, a
perspective for each task. Pass them in `QA_FLAGS`, as make takes long
options for itself:

    make qa QA_FLAGS="--remote --tuned -L ../ghostel/lisp -L ../ghostel-tmux --package-dir ~/.emacs.d/elpa"

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
| Claude Code | 2.1.303, with and without relay; 2.1.310 relayed; 2.1.322 | hook events, notifications, payload fields | hooks given with `--settings` |
| Codex | 0.163.0, with and without relay | hook events and payload fields | hooks given with `-c`, reviewed once in Codex |
| Pi | 1.3.0, 1.5.2 | extension events, context, options | an extension given with `--extension` |
| OpenCode | 1.19.3, 1.19.4 | events, settings | a plugin named in `OPENCODE_CONFIG_CONTENT` |

See [validation](validation.md) for the live runs with Claude Code, Codex and
Pi on local and remote hosts, [the demo notes](demo.md) for how the screenshots
were made, and [MELPA](melpa.md) for the package recipes.
