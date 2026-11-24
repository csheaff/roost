# Roost

[![CI](https://github.com/csheaff/roost/actions/workflows/ci.yml/badge.svg)](https://github.com/csheaff/roost/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/csheaff/roost/badge)](https://scorecard.dev/viewer/?uri=github.com/csheaff/roost)

**Run a fleet of coding agents from Emacs.** Each agent
([Claude Code](https://claude.com/claude-code),
[Codex](https://github.com/openai/codex),
[Pi](https://github.com/earendil-works/pi) or
[OpenCode](https://opencode.ai)) gets a task of its own: a worktree, a
branch and a terminal, here or on any SSH host. Roost tells you which one
needs you, and you review and merge their work with Magit.

![Emacs with three columns: Roost's sidebar listing nine agents on two hosts, the one you are on marked with a band, six ready, one working and one asking permission, with what it asks under it, and a button at its top that collapses it; that agent's Pi terminal, named local › spending-chart in its mode line, where it has read the chart it drew, and the bar chart shows above its reply; and the task's panel, which says to review its changes in Magit and lists the file it changed](docs/images/roost-hero.png)

## A task, start to finish

1. **Start where the work is.** `C-c r c` on an Org heading, a region or an
   issue drafts a task from it. `C-c C-c` starts the agent.

   ![An Org file of plans beside the draft that C-c r c made from its heading, Chart spending by category: Cancel and Create buttons at the top, the project ledger on this machine, the agent pi, one attempt, starting from main and merging into main, the task named chart-spending-category, each with its key beside it, and the heading and its notes as the prompt](docs/images/roost-new-task.png)

2. **Go where you're needed.** `C-c r n` takes you to the next agent waiting
   for you. Answer it in its own terminal.
3. **Read what it said.** `V` sets the conversation as a page in place of
   the terminal, and `V` again brings the terminal back.

   ![The same three columns, with the task's terminal swapped for its conversation set as a page: your question in a quiet bubble, then the agent's answer in a serif, a table of spending by category with each one's share, and a short list of what stands out; the panel's row of views ends in V Back](docs/images/roost-read.png)

4. **Review in Magit.** Click a changed file in the panel for its diff,
   note a line with `;`, and send your notes to the agent with `@`.

   ![A task's terminal above the Magit diff of ledger.py, with a review note under a changed line: the bars come out in the order the entries were imported; sort them largest first, so the chart reads at a glance. Beside them, the task's panel lists the file it changed, one review note for the agent, and the two other tasks that change the same file](docs/images/roost-review.png)

5. **Finish.** `C-c r m` merges the task and cleans up its worktree, branch
   and terminal. `C-c r P` opens a pull request instead.

**Watch them all.** The dashboard lists every agent on every host, with
what it's doing, what it changed and what it asks.

![The dashboard, counting 1 permission, 7 ready and 1 seen: six Pi tasks on dev, five ready and one seen, and three local ones, two Pi tasks ready and a Claude Code task asking to run python3 -m unittest, each with a light in the shape of its status, its agent, its changes, and its latest reply or what it asks](docs/images/roost-dashboard.png)

## What an agent can show you

Ask for a picture, and Roost opens it beside the agent's terminal.

![A task's terminal, named local › vectorise-signals, alone in the frame. Claude Code is asked to show the signals and the reconstruction together; it calls Roost, and a window opens beside the terminal with two images, one over the other: signals.png, red and blue arcs of pressure across a line of detectors against time, and reconstruction.png, two large and five small targets, bright in a hot colour map](docs/images/roost-show-images.gif)

With `(setq roost-agent-pages t)` and an Emacs built with xwidgets, an
agent can write you a page to click and play with.

![A task's terminal, named local › replay-reconstruction, alone in the frame. Claude Code is asked to show the reconstruction building once more; it calls Roost, and a page opens beside the terminal and plays: bright rays sweep across a Shepp-Logan phantom, a sinogram fills in from the left as a heat map, and above them the filtered back projection sharpens from streaks into the phantom as the count of views climbs to 181, over a pause button, a slider and a control for the filter](docs/images/roost-show-page.gif)

A Pi task can show a page as the model writes it (here at twice its speed).

![A task's terminal, named local › explain-back-projection, alone in the frame. Pi is asked to draw back-projection once more with each arc in its detector's colour; a window opens beside the terminal while Pi is still working, and a page fills in: a heading, then a half circle from each of eleven detectors, one after another and each in its own colour, all crossing at a bright target, then the detectors along the bottom and a line on what the arcs are](docs/images/roost-show-as-written.gif)

## Get started

Roost needs Emacs 29.1+, [Ghostel](https://github.com/dakra/ghostel)
0.65.0+ and [ghostel-tmux](https://github.com/dakra/ghostel-tmux) 0.4.0+.
Each host needs Python 3.9+, Git, tmux 3.1+ and a signed-in agent CLI. With
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
  (roost-sidebar-mode 1))                   ; the task list at the left
```

Then `M-x roost-doctor` checks each host, and `C-c r c` in a Git project
starts your first task. The [manual](docs/manual.md#install) covers
straight.el, Doom, Emacs 29 and Evil.

| Key | | Key | |
| --- | --- | --- | --- |
| `c` | New task | `r` | Review in Magit |
| `n` | Next agent waiting | `V` | Read its conversation |
| `RET` | The agent's terminal | `m` | Merge, and retire it |
| `e` | Send a prompt | `P` | Open a pull request |
| `/` | Search conversations | `?` | Every command |

They work in the menu, and alone in the dashboard, the sidebar and a task's
panel.

## Good to know

- Agents run in tmux, each in its own interface, with its menus and slash
  commands as always. Restart Emacs and they are still at work.
- Roost never answers an agent's prompts, never changes your agent
  settings, and never stages or commits your work. It deletes work only
  when you discard a task and type its name.
- Roost is built around Claude Code and checked against each release;
  Codex, Pi and OpenCode tasks show the same statuses.

## More

[The manual](docs/manual.md) has every command and option.
[Changes](CHANGELOG.md) says what to do when upgrading. There's also a
[roadmap](docs/roadmap.md), [how the screenshots were made](docs/demo.md),
and how [Orca](https://www.onorca.dev/), which shaped the workflow,
[compares](docs/orca-comparison.md).

GPL-3.0-or-later.
