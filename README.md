# Roost

[![CI](https://github.com/csheaff/roost/actions/workflows/ci.yml/badge.svg)](https://github.com/csheaff/roost/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/csheaff/roost/badge)](https://scorecard.dev/viewer/?uri=github.com/csheaff/roost)

**Run a fleet of coding agents from Emacs.** Roost gives each agent
([Claude Code](https://claude.com/claude-code),
[Codex](https://github.com/openai/codex),
[Pi](https://github.com/earendil-works/pi) or
[OpenCode](https://opencode.ai)) a task of its own: a Git
worktree, a branch and a terminal, here or on any SSH host. It tells you which
agents need you, and you review and merge their work with Magit. If you've
used Orca, it's that idea, inside Emacs.

![Emacs with three columns: Roost's sidebar listing nine agents on two hosts, the one you are on marked with a band, five ready, one working, one with changes not looked at and one asking permission, with what it asks under it; that agent's Pi terminal, named local › spending-chart in its mode line, where it has read the chart it drew, and the bar chart shows above its reply; and the task's panel, which says to review its changes in Magit and lists the file it changed](docs/images/roost-hero.png)

*Nine agents on two hosts: every task at the left, one agent's terminal in
the middle, and what to do next at the right.*

## A task, start to finish

`C-c r` is Roost's menu, as in the [setup below](#get-started).

1. **Start where the work is.** `C-c r c` on an Org heading drafts a task
   with the heading and its notes as the prompt; a region, a GitHub issue
   or a Jira work item works the same way. `C-c C-c` starts the agent in a
   worktree and branch of its own.

   ![An Org file of plans beside the draft that C-c r c made from its heading, Chart spending by category: Cancel and Create buttons at the top, the project ledger on this machine, the agent pi, one attempt, starting from main and merging into main, the task named chart-spending-category, each with its key beside it, and the heading and its notes as the prompt](docs/images/roost-new-task.png)

2. **Go where you're needed.** `C-c r n` takes you to the next agent
   waiting for you, and you answer it in its own terminal. With
   perspective.el or `tab-bar-mode`, each task has a perspective or tab of
   its own.
3. **Review, and reply in place.** The panel beside the terminal lists the
   files the agent changed. Click one for its diff in Magit, write a note
   on a line with `;`, and send your notes to the agent with `@`.

   ![A task's terminal above the Magit diff of ledger.py, with a review note under a changed line: the bars come out in the order the entries were imported; sort them largest first, so the chart reads at a glance. Beside them, the task's panel lists the file it changed, one review note for the agent, and the two other tasks that change the same file](docs/images/roost-review.png)

4. **Finish.** Once the agent has committed, `C-c r m` squashes the task
   into the branch it started from and removes its worktree, branch and
   terminal. `C-c r P` opens a pull request instead.

**Or talk first.** `C-c r C` opens an agent in no project. Ask it to plan a
piece of work, and each task it proposes waits under the conversation, a
click away from a draft.

**Watch them all.** `M-x roost-dashboard` lists every agent on every host:
what it's doing (`Running make test`), what it changed, and its latest reply
or what it asks. A notification says when one finishes or asks.

![The dashboard, counting 1 permission, 7 ready and 1 seen: six Pi tasks on dev, five ready and one seen, and three local ones, two Pi tasks ready and a Claude Code task asking to run python3 -m unittest, each with a light in the shape of its status, its agent, its changes, and its latest reply or what it asks](docs/images/roost-dashboard.png)

## What an agent can show you

When an agent has a picture for you, Roost opens it beside its terminal.

**Images.** Ask for a plot, a screenshot, or a before and an after. The
agent shows up to six together, and a click on one fills the frame.

![A task's terminal, named local › vectorise-signals, alone in the frame. Claude Code is asked to show the signals and the reconstruction together; it calls Roost, and a window opens beside the terminal with two images, one over the other: signals.png, red and blue arcs of pressure across a line of detectors against time, and reconstruction.png, two large and five small targets, bright in a hot colour map](docs/images/roost-show-images.gif)

**Pages.** With `(setq roost-agent-pages t)`, an agent in a new task can
also write a small page: a diagram you can click, a mock-up, controls to
try. Pages need a graphical Emacs built with xwidgets.

![A task's terminal, named local › replay-reconstruction, alone in the frame. Claude Code is asked to show the reconstruction building once more; it calls Roost, and a page opens beside the terminal and plays: bright rays sweep across a Shepp-Logan phantom, a sinogram fills in from the left as a heat map, and above them the filtered back projection sharpens from streaks into the phantom as the count of views climbs to 181, over a pause button, a slider and a control for the filter](docs/images/roost-show-page.gif)

**As it is written.** A Pi task on this machine shows its page as the
model writes it, when the model's server sends it piece by piece, as
OpenAI's did here (played at twice its speed).

![A task's terminal, named local › explain-back-projection, alone in the frame. Pi is asked to draw back-projection once more with each arc in its detector's colour; a window opens beside the terminal while Pi is still working, and a page fills in: a heading, then a half circle from each of eleven detectors, one after another and each in its own colour, all crossing at a bright target, then the detectors along the bottom and a line on what the arcs are](docs/images/roost-show-as-written.gif)

Pi also draws the images it reads
[inside its terminal](docs/manual.md#images-in-a-terminal), as in the
picture at the top. The [manual](docs/manual.md#a-day-with-roost) has the
keys, sizes and limits.

## Get started

Roost needs Emacs 29.1+, and [Ghostel](https://github.com/dakra/ghostel)
0.65.0+ and [ghostel-tmux](https://github.com/dakra/ghostel-tmux) 0.4.0+ to
draw the terminals. Each host needs Python 3.9+, Git, tmux 3.1+ and a
signed-in agent CLI; remote hosts need SSH with keys or an agent. With
Emacs 30:

```elisp
(use-package ghostel :ensure t)             ; from MELPA

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

Ghostel offers to download its native module the first time a terminal
opens. The [manual](docs/manual.md#install) covers straight.el, Doom, Emacs
29, Evil and other modal setups.

1. `M-x roost-doctor` checks this machine and each host, with a fix for
   anything missing.
2. In a Git project, `C-c r c`, write a prompt, and `C-c C-c`.
3. Answer the agent in its terminal. `C-c ?` there opens Roost's menu.

| Key | | Key | |
| --- | --- | --- | --- |
| `c` | New task | `r` | Review in Magit |
| `n` | Next agent waiting for you | `u` | Bring a task up to date |
| `RET` | The agent's terminal | `m` | Merge it, and retire it |
| `t` | A shell in its worktree | `P` | Open a pull request |
| `e` | Send the agent a prompt | `x` | Retire it, or discard it |
| `/` | Search agents' conversations | `?` | Every command |

These work on the menu, and alone in the dashboard, the sidebar and a
task's panel.

## Good to know

- Agents run in tmux, each in its own terminal interface: its prompts,
  menus and slash commands work as always. Restart Emacs and they are still
  at work; close the laptop and remote ones carry on.
- Roost never answers an agent's prompts, never changes your global agent
  settings, and never stages or commits your work. It deletes work only when
  you discard a task and type its name.
- Roost is built around Claude Code and checked against each new release.
  Codex, Pi and OpenCode tasks show the same statuses; Codex asks before
  each commit, and its approvals show only once it moves on unless
  `roost-program-status` is on.
- Claude Code 2.1.284+ starts in auto mode and rarely asks. To be asked
  before each command, add `"--permission-mode" "manual"` to its entry in
  `roost-agent-commands`.
- Each agent gets three tools from Roost, to offer you tasks, name your
  projects and show you images; `(setq roost-agent-offers nil)` starts
  tasks without them.
- `(setq roost-remote-control t)` shows each Claude task in the Claude app,
  which notifies your phone when its agent needs a decision.

## More

- [The manual](docs/manual.md): every command and option, and how Roost
  works.
- [Changes](CHANGELOG.md), with what to do when upgrading.
- [A possible roadmap](docs/roadmap.md), and the
  [research](docs/research.md) behind it.
- [Validation](docs/validation.md) runs,
  [how the screenshots were made](docs/demo.md), and
  [the MELPA recipes](docs/melpa.md).

[Orca](https://www.onorca.dev/) shaped the workflow; see the
[comparison](docs/orca-comparison.md).

## License

GPL-3.0-or-later.
