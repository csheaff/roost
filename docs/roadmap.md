# A possible roadmap

Ideas for where Roost could go, and what it leaves to other tools. None of
them is promised: each is a candidate, to be tried before it's kept, and
some will be dropped. They're ordered by what matters day to day: knowing
which agent needs you, and seeing a task through to its merge. Each names
the projects it comes from; [Prior art](#prior-art) lists them for the next
look around.

## Most likely first

Small, and probably worth the most.

- **Conflicts before merge time.** Roost finds a conflict only when `m`
  refuses. Running `git merge-tree` as tasks change, against the integration
  branch and the project's other tasks, lets the panel say "conflicts with
  main in foo.py" or "task X also changes foo.py" while `u` is still cheap.
  This covers committed work; for uncommitted work, compare changed files.
  From Calyx's Mission Map, which marks agents that edited the same file
  within five minutes.
- **Your phone, through Claude Code's Remote Control.** Start each Claude
  task with `--remote-control`, named after the task, so it shows in the
  Claude app and at claude.ai/code. Both send a push notification when an
  agent needs a decision. Point `CLAUDE_CLIENT_PRESENCE_FILE` on each host
  at a file Roost keeps while Emacs has focus, so pushes come only when
  you're away. Herdr, Orca, Superset, cmux and agent-deck each built a
  phone app for this.
- **`.worktreeinclude`.** Copy the ignored files it lists, such as `.env`,
  into new worktrees, as Claude Code and Conductor do. Today that takes
  `roost-setup-command`.
- **0.9, and MELPA.** tmux-control first; see [the recipes](melpa.md).

## Worth trying

- **Usage limits.** Claude Code gives its status line command the five-hour
  and weekly limits (`rate_limits`, with `used_percentage` and `resets_at`).
  A shim that records them and then runs your own status line, as
  agent-deck's does, would show them in the sidebar and mode line, and for a
  task stopped by a limit, when it resets. Pro and Max plans only, and each
  session reports what it saw last. Orca shows usage in its status bar.
- **Scripts beyond setup.** A teardown command before a worktree is removed,
  a check command that must pass before `m`, and a block of ports per task
  (`$ROOST_PORT`) so two tasks' servers don't collide. A remote task's port
  can be forwarded over the SSH connection Roost already shares. From
  Conductor (setup, run and archive scripts, ten ports per workspace),
  workmux (`pre_merge` and `pre_remove` hooks that can stop the operation),
  Superset and agent-deck.
- **An Org entry's TODO state follows its task.** A linked entry
  (`ROOST_TASK`) moves through its keywords as the task starts, waits for
  review and merges, so the agenda becomes the board; off by default.
  Unchecked checkboxes in the entry warn before `m`. From Orca's workflow
  states, Conductor's todos that block a merge, and the kanban
  orchestrators (Vibe Kanban, openkanban, agent-deck's fleet board).
- **Images and files for remote tasks.** An agent on a remote host can't see
  this machine's clipboard. Copy a file or a clipboard image to the task's
  host and put its path in the prompt. cmux and Orca upload to remote
  sessions.
- **Resuming a host's tasks after it restarts.** After a reboot, each task
  waits for `s`. Offer to resume them all when a host's tmux server is
  gone. Herdr resumes agents when it restores a session; workmux has
  `resurrect`.
- **Several attempts at one prompt.** A count, or several agents, in the
  draft makes sibling tasks; compare them in Magit, merge one, and finish
  the rest. From Orca ("fan one prompt across 5 agents"), dmux and workmux
  (`-a`, `-n`).
- **Better task names.** Names come from a prompt's first words, and `R`
  renames a task. Claude Code titles its sessions itself, in an `ai-title`
  line of the transcript (or the name its `/rename` gave), which `R` could
  offer, doing nothing for an agent that keeps no title; Pi's sessions
  hold none, and Codex's CLI is unchecked. A model call on the host is
  the other way. From dmux, workmux (`-A`), Orca and agent-deck.
- **Review notes from file buffers**, for diff-hl users who review in the
  file rather than in Magit.
- **Ghostel in place of Eat.** [Ghostel](https://github.com/dakra/ghostel)
  runs Ghostty's terminal engine in Emacs as a native module, with the Kitty
  keyboard and graphics protocols and synchronized output, and its author
  measures it faster than vterm. tmux-control would draw panes with it
  instead of Eat. First check that Ghostel can show output it doesn't read
  from its own process. The module is a prebuilt download, one more thing to
  install.

## Exploring

Larger, or undecided.

- **Agents that start Roost tasks.** A `roost` command inside a task, served
  by the helper already on each host, so a coordinating agent can split work
  into tasks you still review and merge. The busiest idea in the field:
  herdr's `agent start`, `prompt`, `wait` and `read`, workmux's
  `/coordinator` skill, Superset's MCP server, agent-deck's conductor. It
  pulls toward an orchestration Roost may not want.
- **What changed since you last looked.** A snapshot of the worktree in a
  private ref at each prompt, for a Magit diff of one turn, or of everything
  since your last review, the agent's commits included. From Conductor's
  checkpoints. Rewinding stays the agent's (`/rewind`).
- **A map of the agent's work** beside its terminal: the files it reads and
  edits over time, drawn with Emacs 32's canvas images. Prototype on branch
  `work-map`.
- **Conversation tasks** over Claude Code's stream-json, typeset rather than
  in a terminal. Parked: it has to be as dense as the terminal first. Branch
  `reader-prototype`.
- **Other kinds of task:** someone else's branch or pull request to review,
  an existing branch to continue, and work in place without a worktree,
  such as dotfiles. Today, fetch the ref and start a task from it with
  `C-c C-b` in the draft.
- **Rex in place of tmux.** [Rex](https://www.superlogical.com/rex/docs),
  from Superlogical, is a terminal and multiplexer built on Ghostty's
  engine, in beta on macOS since 2026-10-05. Its server API covers what the
  helper asks of tmux: start a terminal running a command in a folder, type
  into it, close it, and push events for its exit code and its program
  status (OSC 7501, which tmux blocks; see
  [tmux#5713](https://github.com/tmux/tmux/issues/5713)). Its IDs are never
  reused, so a stale ID can't reach another terminal. Missing: a documented
  way for Emacs to attach to a terminal and stream it, as tmux-control does
  with control mode, and Rex servers on Linux outside Superlogical. Ask for
  the first in the beta. Look again once both exist, or once tmux turns
  down OSC 7501 for good.

## Known gaps

- Codex's sandbox keeps a worktree's shared `.git` read-only, so Codex asks
  before each commit.
- An approval of a tool other than Bash, and any Codex or Pi approval, shows
  `permission` until the agent moves on. Claude Code has no hook for an
  answered permission or an interrupt; both would be requests upstream.
- While you write a commit message in a remote task, Magit can't show the
  diff beside it ("Error showing commit diff"); the commit goes through.
  The bug is Magit's, with any TRAMP method: from a linked worktree's Git
  directory, `magit-toplevel` drops the TRAMP prefix.

## Not planned

- **Answering the agent's prompts from Roost** (approval inboxes, approve
  keys). The agent's own terminal stays the way you talk to it, so its
  menus and new features work on day one. Calyx and octomux have inboxes.
- **Watching a pull request for the agent:** review comments and failed
  checks turned into prompts, or fixed on their own. The agents do this:
  Claude Code can subscribe a session to its pull request's reviews and CI,
  and autofix it. Roost keeps `P`, the `#12` line with checks and review,
  and `x` once it merges; when the agent's watcher sets it to work, the
  status lights show it like any other turn.
- **A docked review column.** Magit, opened with `r`, stages and takes
  notes; see [the Orca comparison](orca-comparison.md#review-notes-and-staging-in-magit).
- **Built-in browsers and design modes** (Orca, cmux, Superset), **a kanban
  view** (Org's agenda instead), **containers** for now (agent-deck,
  workmux), and **scheduled runs** (Orca, Codex, Superset), which need
  something always running; cron on the host does that.

## Prior art

Surveyed 2026-10-11 from documentation and READMEs; Orca was also used
hands-on (see the [comparison](orca-comparison.md)). New ideas show up first
in changelogs.

| Project | What it is | Worth a look |
| --- | --- | --- |
| [Orca](https://www.onorca.dev/) ([changelog](https://www.onorca.dev/changelog)) | Desktop app: a worktree per task, SSH hosts, a phone app | Usage meters, automations, several attempts per prompt, native chat |
| [herdr](https://herdr.dev) | Terminal workspace that keeps agents' terminals in a background server; SSH machines | [Agent CLI and socket API](https://herdr.dev/docs/agent-automation/), [session restore](https://herdr.dev/docs/session-state/) |
| [Rex](https://www.superlogical.com/rex/docs) | Terminal and multiplexer from Superlogical, on Ghostty's engine; macOS beta | [Server API](https://www.superlogical.com/rex/docs/automate/server-api), [events](https://www.superlogical.com/rex/docs/reference/events), [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status) |
| [Conductor](https://www.conductor.build/docs/) | macOS app: a worktree per task | [Scripts and ports](https://www.conductor.build/docs/reference/scripts), [checkpoints](https://conductor.build/docs/reference/checkpoints), [todos](https://conductor.build/docs/reference/todos) |
| [Superset](https://github.com/superset-sh/superset) | Desktop editor for many agents | Workspace scripts, ports per worktree, MCP server, automations |
| [cmux](https://github.com/manaflow-ai/cmux) | Ghostty-based macOS terminal | Notifications from escape sequences and hooks, image upload over SSH, ports and pull requests in the sidebar |
| [Calyx](https://github.com/yuuichieguchi/Calyx) | Native macOS terminal | Mission Map (same-file edits), approval inbox, usage tracking |
| [agent-deck](https://github.com/asheshgoplani/agent-deck) | tmux TUI with remote instances | Forking, conductor, usage from the status line, hooks approved by hash |
| [workmux](https://github.com/raine/workmux) | Worktrees and tmux windows | Lifecycle hooks, copied files, `resurrect`, `/coordinator`, batch prompts |
| [dmux](https://github.com/standardagents/dmux) | tmux agent multiplexer | Several agents per prompt, generated names, lifecycle hooks |
| [Claude Squad](https://github.com/smtg-ai/claude-squad) | tmux TUI, among the first | Pausing a task and checking it out |
| Claude Code | The agent itself | [Agent view](https://code.claude.com/docs/en/agent-view) (`claude agents`), [Remote Control](https://code.claude.com/docs/en/remote-control), [worktrees](https://code.claude.com/docs/en/worktrees) |
| [Codex app](https://developers.openai.com/codex/app) | OpenAI's desktop app | Automations and their review queue |
| [agent-shell](https://github.com/xenodium/agent-shell), [claude-code.el](https://github.com/stevemolitor/claude-code.el), [M-x Machina](https://github.com/eliraz-refael/m-x-machina) | Agents inside Emacs | |
| [Ghostel](https://github.com/dakra/ghostel) | Emacs terminal on Ghostty's engine | Kitty keyboard and graphics protocols, synchronized output |

[awesome-agent-orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators)
tracks about 250 more; its terminal section is closest to Roost.
