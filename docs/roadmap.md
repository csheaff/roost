# A possible roadmap

Ideas for where Roost could go, and what it leaves to other tools. None of
them is promised: each is a candidate, to be tried before it's kept, and
some will be dropped. They're ordered by what matters day to day: knowing
which agent needs you, and seeing a task through to its merge. Each names
where it comes from; [Prior art](#prior-art) lists the projects for the next
look around.

The Claude Code team's account of
[how it reviews code](https://claude.dev/blog/solving-code-review-at-anthropic/)
(2026-10-15) shapes several of them. There, agents check their own work and
an AI reviewer reads every pull request, so people read fewer diffs and
make more decisions: whether to build something, which changes are risky,
and whether the evidence holds up. Some people will want to work that way,
and some will go on reading every diff. Roost should serve both: these
ideas add what you need when you don't read every line, such as when a
decision is yours and what it rests on, and take nothing from review in
Magit.

## Most likely first

Small, and probably worth the most.

- **Ready for MELPA.** Keep tmux-control and Roost passing MELPA's checks,
  with [the recipes and their status](melpa.md) current, and send them,
  tmux-control first, once people ask for them there. Features don't wait
  for it.
- **[When a merge is your turn](#when-a-merge-is-your-turn)**, its first
  three parts: a pull request waiting on you counts as waiting, conflicts
  before merge time, and what changed since you last looked.
- **`.worktreeinclude`.** Copy the ignored files it lists, such as `.env`,
  into new worktrees, as Claude Code and Conductor do. Today that takes
  `roost-setup-command`.
- **Your phone, through Claude Code's Remote Control.** An option to start
  each Claude task with `--remote-control`, named after the task, so it
  shows in the Claude app and at claude.ai/code. Both send a push
  notification when an agent needs a decision; until Roost keeps a presence
  file ([Worth trying](#worth-trying)), they also do it while you're at
  Emacs. Passing `--name` too would show the task's name in Claude's
  `/resume` picker; Roost names only the tmux window today. Herdr, Orca,
  Superset, cmux and agent-deck each built a phone app for this.

## When a merge is your turn

These ideas answer one question about each task: is a merge your turn, and
what would it rest on? They share the places where Roost already says what
a task needs: the next step at the top of the task panel and the menu (for
an open pull request, today it only says that `P` pushes new commits), the
status word in the sidebar, and `n`. Each adds a line or a status there
rather than a view of its own. The first three are among the most likely;
the last two are worth trying once those show what the panel has room for.

- **A pull request waiting on you counts as waiting.** Roost asks GitHub
  about pushed tasks every two minutes and shows `#12` with its checks and
  review, but `n` and the status lights follow only the agent, and a pull
  request that's ready for you gives the agent nothing to say. It's your
  turn to merge when the pull request is open at the branch's tip, every
  check passed, no requested review is still pending (Copilot's included),
  no thread is unresolved, and the agent neither works nor asks. It's your
  turn to nudge when a check failed or a thread is open and, a minute or
  two later, the agent still hasn't started a turn: an agent that watches
  its own pull request starts one and never gets here, and one that
  doesn't, does, so Roost needn't know which kind it runs. Most of this
  comes with the `gh pr list` Roost already runs, asking also for
  `mergeable`, `mergeStateStatus` and `reviewRequests`; unresolved threads
  take a GraphQL query. Copilot only comments, so `reviewDecision` doesn't
  move for it; its threads and a pending re-review do. The agent still
  does the fixing; Roost says when it's your turn. From the Claude Code
  team's review, in which people step in only where the checks can't
  settle a change.
- **Conflicts before merge time.** Roost finds a conflict only when `m`
  refuses. GitHub already says when a pushed task's pull request conflicts
  (`mergeable`, in the query above). For the rest, running `git merge-tree`
  against the integration branch whenever either tip moves lets the panel
  say "conflicts with main in foo.py" while `u` is still cheap. That covers
  committed work; the changed files Roost already lists for each task,
  committed or not, can say "task X also changes foo.py". From Calyx's
  Mission Map, which marks agents that edited the same file within five
  minutes.
- **Since you last looked.** Record the commit a task was at when you last
  opened `r` or sent its agent notes, and show "3 commits since you last
  looked" on its row and panel. `r` shows those commits in a section of
  their own, beside "Unmerged into main", and `m` and `P` say so when
  commits landed since. "Looked" rather than "reviewed", since Roost can't
  tell when a review ends; a key of its own is the other way. Agents that
  go on fixing after you look, in reply to CI or a reviewer, make this
  matter. From the Claude Code team's approvals, which hold for one commit
  and lapse when unreviewed ones land. Rewinding stays the agent's
  (`/rewind`).
- **Evidence beside the files in the task panel.** Show what a decision can
  rest on without opening the diff: the pull request's checks, the
  reviewer's findings still open, the size of the change, and any paths
  marked as risky (below). That's enough to finish a small change that
  passed everything, or to pick the one worth reading closely; the file list
  and Magit stay as they are. Before a pull request, the agent's own test
  output stays in its terminal. From the Claude Code team's review, where
  people judge a change by its evidence more than by its lines.
- **Marks for risky changes.** A list of paths per project, in
  `.dir-locals.el` or the repository's CODEOWNERS, marks tasks whose changes
  touch them, such as CI workflows, authentication or releases, in the
  sidebar and dashboard. That says which diffs to read closely, whether or
  not you read the rest. Large changes get a mark too: the Claude Code team
  finds that most pull requests over 1,000 lines have findings. Roost only
  marks; it approves and merges nothing on its own. From the same post's
  risk tiers, which come from the change, not its author.

## Worth trying

- **Pushes only when you're away.** Point `CLAUDE_CLIENT_PRESENCE_FILE` on
  each host at a file Roost keeps while Emacs has focus, so Remote Control
  stops pushing while you're at Emacs. Claude counts you present whenever
  the file exists, however old it is, so a closed lid or a dropped SSH
  connection would leave it behind and silence the phone just when you're
  away. Something on the host has to remove it once Emacs stops refreshing
  it; each task's runner could.
- **Usage limits.** Claude Code gives its status line command the five-hour
  and weekly limits (`rate_limits`, with `used_percentage` and `resets_at`).
  A shim that records them and then runs your own status line, as
  agent-deck's does, would show them in the sidebar and mode line, and for a
  task stopped by a limit, when it resets. Pro and Max plans only, and each
  session reports what it saw last. Orca shows usage in its status bar.
- **Scripts beyond setup.** A teardown command before a worktree is removed,
  a check command that must pass before `m` (the local stand-in for the CI
  a pull request runs, which `m` skips), and a block of ports per task
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
- **Attachments when starting a task, and straight from Scrawl.** `C-c C-a`
  attaches a file to a prompt for a running task; the new task draft could
  take one too, copied once the task exists. Scrawl sends a capture of a dev
  site to the OpenCode session working on it; given a command to run
  instead, it could reach the task whose worktree serves that page. cmux and
  Orca upload to remote sessions.
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
- **A snapshot at each prompt.** A commit of the worktree under a private
  ref as each prompt is sent, uncommitted work included, would give a diff
  of one turn, and "since you last looked" could start from one. It takes
  a hook at each prompt for every agent, and it writes commits into the
  user's repository, if only under a private ref, which sits uneasily with
  never committing their work. Claude Code's `/rewind` and Conductor's
  checkpoints keep such snapshots themselves.
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
- **Claude Code's own background sessions.** Claude Code now runs sessions
  in the background itself (seen in 2.1.302): `claude --bg` starts one,
  `claude agents` lists them, and `attach`, `logs` and `respawn` act on
  them. `claude agents --json` lists running sessions, interactive ones
  included, each busy or idle. For someone who runs only Claude on one
  machine, that covers part of what Roost does: seeing which sessions are
  busy, and coming back to one. Roost's part is what spans agents and
  hosts: Codex and Pi beside Claude, remote hosts, worktrees through to
  their merge, and review in Magit. As a backend it would serve Claude
  tasks only, so tmux would stay for the rest, and as a source of status
  it says less than the hooks.

## Known gaps

- Codex's sandbox keeps a worktree's shared `.git` read-only, so Codex asks
  before each commit.
- An approval of a Claude Code tool other than Bash, and any Codex
  approval, shows `permission` until the agent moves on. Neither has a hook
  for an answered request, and Claude Code none for an interrupt; those
  would be requests upstream (Pi's dialogs have them, from 0.84.4). With
  `roost-program-status` on (experimental), Claude Code 2.1.295, Codex
  0.163.0 and Pi 1.1.0 and later report through the terminal instead,
  which closes this for all three. It could become the default once it has
  had some weeks of daily use and its protocol, still changing, settles.
- Codex reports only whether it works, waits on you or idles, and works
  between turns too, while its servers start or a command it left running
  runs. So its hooks say when a turn starts and ends, and with
  `roost-program-status` on, a turn that starts before you trust them, as
  a new task's first one can, shows `ready` while Codex works.
- A Pi extension's dialog names only its title ("Run this command?"), not
  what it asks about, so that is all the request shows.
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
  and autofix it, though in 2.1.302 that comes from a tool
  (`subscribe_pr_activity`) a plain CLI session may not have. Roost keeps
  `P`, the `#12` line with checks and review, and `x` once it merges; when
  the agent's watcher sets it to work, the status lights show it like any
  other turn. Saying when a pull request waits on you is Roost's
  ([above](#when-a-merge-is-your-turn)), whether or not the agent watches;
  fixing what it finds is the agent's.
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
| Claude Code | The agent itself | [Agent view](https://code.claude.com/docs/en/agent-view) (`claude agents`) and background sessions (`--bg`, `attach`), [Remote Control](https://code.claude.com/docs/en/remote-control), [worktrees](https://code.claude.com/docs/en/worktrees) |
| [Codex app](https://developers.openai.com/codex/app) | OpenAI's desktop app | Automations and their review queue |
| [agent-shell](https://github.com/xenodium/agent-shell), [claude-code.el](https://github.com/stevemolitor/claude-code.el), [M-x Machina](https://github.com/eliraz-refael/m-x-machina) | Agents inside Emacs | |
| [Ghostel](https://github.com/dakra/ghostel) | Emacs terminal on Ghostty's engine | Kitty keyboard and graphics protocols, synchronized output |

[awesome-agent-orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators)
tracks about 250 more; its terminal section is closest to Roost.
