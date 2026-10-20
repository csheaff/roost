# Roost

[![CI](https://github.com/csheaff/roost/actions/workflows/ci.yml/badge.svg)](https://github.com/csheaff/roost/actions/workflows/ci.yml)

**Run a fleet of coding agents from Emacs.** Roost gives each agent
([Claude Code](https://claude.com/claude-code),
[Codex](https://github.com/openai/codex),
[Pi](https://github.com/earendil-works/pi) or
[OpenCode](https://opencode.ai)) a task of its own: a Git
worktree, a branch and a terminal, here or on any SSH host. It tells you which
agents need you, and you review and merge their work with Magit. If you've
used Orca or Conductor, it's that idea, inside the Emacs you already use.

![Emacs with three columns: Roost's sidebar listing six agents on two machines, the one you are on marked with a band and asking permission, four ready and one working; that agent's Claude Code terminal on the SSH host claylien, asking to run python3 -m unittest; and the task's panel, which says to answer it in its terminal and shows the prompt it was given and the files it has changed](docs/images/roost-hero.png)

*Six Claude Code agents on two machines. The one on `claylien` wants to run
its tests: its own terminal in the middle, every task at the left, and at the
right what to do next, what you asked it and what it changed.*

## A task, start to finish

https://github.com/user-attachments/assets/674d01cc-2a8d-491a-ba9f-6605e48f997e

*One task, from a heading in an Org file to `main`, in about a minute. The
agent's work plays four times faster, and the title bar shows the keys
pressed. `C-c r` opens Roost's menu, as in the setup [below](#get-started);
in the dashboard, the sidebar and a task's panel its keys work alone.*

1. **Start where the work is.** `C-c r c` on an Org heading drafts a task,
   with the heading and its notes as the prompt; a selected region or a
   GitHub issue works the same way. `C-c C-c` makes the worktree and branch
   and starts the agent.
2. **Go where you're needed.** While it works, an agent on `claylien` asks to
   run its tests. `C-c r n` takes you to the next agent waiting for you, and
   you answer it in its own terminal.
3. **Review, and reply in place.** The panel beside the terminal lists the
   files the agent changed. A click opens one's diff in Magit, `;` writes a
   note on a line, and `@` sends your notes to the agent. `C-c r r` opens
   Magit on the whole worktree, over TRAMP for a remote task.
4. **Finish.** The agent revises and commits. `C-c r m` squashes the task
   into the branch it started from and removes its worktree, branch and
   terminal. On the same menu, `u` brings a task up to date first, and `P`
   opens a pull request instead.

**Watch them all.** `M-x roost-status` lists every agent on every host: what
it's doing, what it changed, and its latest reply or what it asks. A
notification says the same when one finishes or asks for something.

![The dashboard: two tasks on claylien, one asking to run python3 -m unittest, and four local ones, three finished and one working, each with its changes and latest reply](docs/images/roost-dashboard.png)

## How it differs

Other Emacs packages run coding agents too, among them
[agent-shell](https://github.com/xenodium/agent-shell),
[claude-code.el](https://github.com/stevemolitor/claude-code.el) and
[M-x Machina](https://github.com/eliraz-refael/m-x-machina). Roost differs in
three ways:

- **Agents run outside Emacs.** Each one runs in tmux, and Emacs shows its
  terminal. Restart Emacs, and an agent at work is still at work, rather than
  resumed from its saved conversation.
- **On any machine you can reach over SSH.** One dashboard covers this
  machine and your remote hosts, and Magit reviews their work over TRAMP,
  fastest with [tramp-rpc](docs/manual.md#fitting-your-setup).
  Close the laptop, and a remote agent carries on.
- **It sees a task through.** Each task has its own worktree and branch. You
  review it in Magit and send notes on its lines back to the agent; Roost
  brings it up to date, merges it or opens a pull request, and cleans up.

Each agent keeps its own terminal interface, so its prompts, menus and slash
commands work as they always do, new ones included. Roost adds what lives
outside the agent.

## Get started

Roost needs Emacs 29.1 or newer and
[tmux-control](https://github.com/csheaff/tmux-control) 0.8.1 or newer. Each
host needs Python 3.9+, Git, tmux 3.1+ and a signed-in agent CLI; remote hosts
need SSH with keys or an agent. With Emacs 30:

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

For straight.el, Doom, Emacs 29, Evil and other modal setups, see the
[manual](docs/manual.md#install).

1. `M-x roost-doctor` checks this machine and each host, with a fix for
   anything missing.
2. In a Git project, `C-c r c`, write a prompt, and `C-c C-c`.
3. Answer the agent in its terminal. `C-c ?` there opens Roost's menu.

| Key | | Key | |
| --- | --- | --- | --- |
| `c` | New task | `r` | Review in Magit |
| `n` | Next agent waiting for you | `u` | Bring a task up to date |
| `RET` | The agent's terminal | `m` | Merge it, and clean up |
| `t` | A shell in its worktree | `P` | Open a pull request |
| `e` | Send the agent a prompt | `x` | Finish: retire, or discard |
| `/` | Search agents' conversations | `?` | Every command |

These work in the dashboard, the sidebar and a task's panel, and on the menu.

## Good to know

- Roost is built around Claude Code and checked against each new release of
  it. Codex, Pi and OpenCode tasks show the same statuses; Codex asks before
  each commit, and its approvals show only once it moves on unless
  `roost-program-status` is on.
- Roost never answers an agent's prompts, never changes your global agent
  settings, and never stages or commits your work. It deletes work only when
  you discard a task and type its name.
- Claude Code starts in auto mode for some accounts and rarely asks. To be
  asked before each command, add `"--permission-mode" "manual"` to its entry
  in `roost-agent-commands`.

## More

- [The manual](docs/manual.md): every command and option, a day of work in
  detail, and how Roost works.
- [Changes](CHANGELOG.md), with what to do when upgrading.
- [A possible roadmap](docs/roadmap.md): ideas being considered, and the
  tools they come from.
- [Validation](docs/validation.md): live runs with Claude Code and Codex, on
  local and remote hosts. [How the screenshots and the clip were
  made](docs/demo.md), and [the MELPA recipes](docs/melpa.md).

[Orca](https://www.onorca.dev/) shaped the workflow: a worktree per task, a
terminal nearby, review before finishing. See the
[comparison](docs/orca-comparison.md).

## License

GPL-3.0-or-later.
