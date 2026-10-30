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

[A look through research](research.md) on supervising many agents at once
(2026-10-20), from drones and process control to interruptions, code review
and the first studies of people running coding agents in parallel, orders
several of them. Most people run two to four agents, and the one controlled
trial of a dashboard for them raised that by about one
([ParallelPilot](https://arxiv.org/html/2609.33113v1)). Roost's noticing of
which agent needs you mostly matches the evidence. What limits how many
agents one person keeps up with now is the time it takes to judge each
change, whether you read every line or judge by the evidence, and keeping
tasks out of each other's files. So the ideas that cut those come first, and
more work on noticing after them.

## Most likely first

Small, and probably worth the most.

- **Ready for MELPA.** Keep tmux-control and Roost passing MELPA's checks,
  with [the recipes and their status](melpa.md) current, and send them,
  tmux-control first, once people ask for them there. Features don't wait
  for it.
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
a task needs: the next step at the top of the task panel and the menu, the
status word in the sidebar, and `n`. Each adds a line or a status there
rather than a view of its own. Four that came before are in Roost now: a
pull request that waits on you counts as waiting, conflicts show before
merge time, each task says what changed since you last looked, and the
task panel shows what a merge rests on beside the files: the pull request's
checks by name, with "No CI results" unlike "passed", its open review
threads with file and line, and the agent's latest reply, as its own
account, with no badge or verdict.

- **Marks for risky changes.** Large changes have theirs: a dim `±` on the
  row once a task's changes reach 400 lines, 10 files or 3 top-level
  directories (`roost-large-change`), with the size in the task panel.
  Those are where studies of people reviewing code find that they catch
  less as changes grow and spread, rather than the 1,000 lines past which
  the Claude Code team's AI reviewer usually finds something. What's left
  is risky paths: a list per project, in `.dir-locals.el` or drawn from the
  repository's CODEOWNERS, marks tasks whose changes touch them, such as CI
  workflows, authentication or releases, in the sidebar and dashboard. That
  says which diffs to read closely, and with the size, which hour of
  reading. CODEOWNERS often gives every path an owner, so it would need a
  list of its own of the paths that count. Roost only marks; it approves
  and merges nothing on its own. From the same post's risk tiers, which
  come from the change, not its author.

## Worth trying

- **A quiet word for a stalled task.** The task panel and dashboard say how
  long since an agent's last event ("for 14m"); the sidebar doesn't. A dim
  `quiet` there, for a working task far past its own usual gap between
  events, would point at an agent that hangs or loops, without counting it
  as waiting. Going by the task's own gaps rather than one fixed time
  spares a task whose tests always take a while. An unexpected delay was
  one of the four signs ParallelPilot's developers watched their agents
  for, and its dashboard marks one
  ([ParallelPilot](https://arxiv.org/html/2609.33113v1)); slow, hung or
  runaway work is behind 17% of the times people interrupt Claude
  ([Anthropic](https://www.anthropic.com/research/measuring-agent-autonomy)).
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
  a pull request runs, which `m` skips, its result under the task panel's
  Checks, saying it ran here), and a block of ports per task
  (`$ROOST_PORT`) so two tasks' servers don't collide. A remote task's port
  can be forwarded over the SSH connection Roost already shares. From
  Conductor (setup, run and archive scripts, ten ports per workspace),
  workmux (`pre_merge` and `pre_remove` hooks that can stop the operation),
  Superset and agent-deck.
- **Notifications held while you review.** Notifications that don't block
  an agent already gather for a minute into one, and permission requests go
  at once. This builds on that: while you review or merge one task, in its
  Magit status or notes, or write it a prompt, those from other tasks could
  go on gathering, a few minutes at most, and come when you leave; the mode
  line's count still moves. Interruptions of a few seconds doubled to
  tripled the mistakes people made in keeping their place in a sequence of
  steps
  ([Altmann et al. 2014](https://www.interruptions.net/literature/Altmann-JExpPsycholGen14.pdf)),
  and holding notifications until the next break cut frustration by a fifth
  ([Iqbal and Bailey 2010](https://www.interruptions.net/literature/Iqbal-TOCHI10.pdf)).
  That system had to guess when a break came, and was right about 40% of
  the time; Roost knows when you're in Magit or a merge, but nobody has
  tried this with Roost's events.
- **An Org entry's TODO state follows its task.** A linked entry
  (`ROOST_TASK`) moves through its keywords as the task starts, waits for
  review and merges, so the agenda becomes the board; off by default.
  Unchecked checkboxes in the entry warn before `m`. From Orca's workflow
  states, Conductor's todos that block a merge, and the kanban
  orchestrators (Vibe Kanban, openkanban, agent-deck's fleet board).
  `roost-task-status-functions` and `roost-task-merged-functions` can
  already drive it from your own configuration.
- **Other tasks' changes in your file buffers.** Visiting a file that
  another task has changed, a header line names those tasks and their
  status, with a click for that task's diff of the file. Most useful in the
  primary checkout, where you otherwise find a conflict only at `m`. A new
  task's draft already names the tasks that change a file it quotes, and
  the task panel those that change its own files.
- **Since you last looked, in the fringe.** Point diff-hl at the commit
  Roost keeps of where you last looked, in a task's worktree, so a file
  shows only what changed since, in your own buffer.
- **Hunks changed since you staged.** Staging is the finest record of what
  you approved, and Magit shows what changed after it as unstaged. A count
  on the row, "3 hunks changed since you staged", would say at hunk level
  what "since you looked" says by file.
- **Attempts compared with Ediff.** With several attempts at one prompt,
  compare two attempts' worktrees file by file in Ediff and take hunks from
  each, rather than picking one.
- **An attach command for other terminals.** Copy the `ssh -t … tmux
  attach` that reaches a task's real terminal, for a phone's SSH app or
  another machine, for every agent rather than Claude only.
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
  (`-a`, `-n`). Of the ideas here, it and
  [agents that start tasks](#exploring) add the most to review without
  making any of it quicker to judge, so it fits where attempts are cheap to
  compare, as with Ediff (above).
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
  keyboard and graphics protocols and synchronized output. tmux-control
  would draw panes with it instead of Eat. Speed is no longer the reason to
  move for terminals you can see. With four agents streaming, Ghostel used
  less than half the Emacs CPU Eat did (draft
  [#78](https://github.com/csheaff/roost/pull/78)), but most of Eat's was
  Emacs redrawing after every chunk. tmux-control 0.8.3 redraws a streaming
  terminal at most 30 times a second, and Eat now uses about what Ghostel
  did ([validation](validation.md), 2026-10-26). Terminals out of sight
  still cost: ten streaming with one shown take 65% of a core. An option
  for tmux to pause the output of terminals no window shows would bring
  that to about 12%; Ghostel wasn't measured with hidden terminals. First
  check that Ghostel can show output it doesn't read from its own process.
  The module is a prebuilt download, one more thing to install.
- **A second sign on the count, beside colour.** The mode line's
  `● Roost:2` and the sidebar's `2 waiting` tell an agent that asks from
  one that failed or finished by colour alone. For a protanope, ef-dream's
  `ready` and `error` are 2.2 apart (CIEDE2000), so the same colour; the
  views beside them have words. A mark while an agent asks, such as
  `Roost:2!`, or why in the count's help-echo, would add the second
  channel WCAG's use of colour and Carbon's
  [status pattern](https://www.carbondesignsystem.com/patterns/status-indicator-pattern)
  ask for. From the [UX review of 2026-10-23](validation.md).

## Exploring

Larger, or undecided.

- **Agents that start Roost tasks.** A `roost` command inside a task, served
  by the helper already on each host, so a coordinating agent can split work
  into tasks you still review and merge. The busiest idea in the field:
  herdr's `agent start`, `prompt`, `wait` and `read`, workmux's
  `/coordinator` skill, Superset's MCP server, agent-deck's conductor. It
  pulls toward an orchestration Roost may not want, and like several
  attempts at one prompt, it makes more to review without making any of it
  quicker to judge. In ParallelPilot's trial, the developer saw and could
  change the planner's split before any agent started
  ([ParallelPilot](https://arxiv.org/html/2609.33113v1)), so a split here
  would wait for your yes too.
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
- **Tasks in Coder workspaces.** A task on a machine that
  [Coder](https://coder.com) makes from a template your administrator
  prepared, such as one with a GPU, chosen by the template's parameters,
  and used in Roost as any other task: its terminal, its panel, Magit. A
  first version is on the integration branch `coder-integration`, tried
  with a CPU template and a fake agent but not a GPU; whether it belongs in
  Roost is still open. Tracked in
  [#146](https://github.com/csheaff/roost/issues/146): work on it branches
  off `coder-integration`, not main.
- **Chosen plugins on a task's host.** A skill reaches a task on another
  host only once you install it there
  ([the manual](manual.md#where-a-tasks-skills-come-from)). Roost could copy
  a plugin folder you name to each host, under its content hash as it does
  the helper, and start Claude with `--plugin-dir`, which loads a plugin for
  that session only and leaves `~/.claude` alone; other agents' adapters
  would pass their equivalent, or nothing. To find out first: whether
  resuming a task keeps the plugin, how its skills are named
  (`plugin:skill`), and what happens when the same plugin is also installed
  on the host. It is a new option and a copy at each start, so it has to do
  better than installing the plugin on the host yourself. From
  [#177](https://github.com/csheaff/roost/issues/177); Orca has a skill
  manager that installs skills into each agent's folders, one host at a
  time.
- **A snapshot at each prompt.** A commit of the worktree under a private
  ref as each prompt is sent, uncommitted work included, would give a diff
  of one turn, and "since you last looked" could start from one. It takes
  a hook at each prompt for every agent, and it writes commits into the
  user's repository, if only under a private ref, which sits uneasily with
  never committing their work. Claude Code's `/rewind` and Conductor's
  checkpoints keep such snapshots themselves.
- **How often merged work came back.** For each agent, or each kind of
  task, how often its merged work was reverted or fixed again soon after,
  perhaps in `M-x roost-workload`. Feedback on how things turned out is the
  best-supported remedy in research on vigilance, and people who had seen
  automation fail checked it more afterwards
  ([Bahner et al. 2008](https://doi.org/10.1016/j.ijhcs.2008.06.001)). But
  whether such rates teach anyone how far to trust an agent's code is
  unknown, and "fixed soon after" needs a definition Git can answer.
- **Rex in place of tmux.** [Rex](https://www.superlogical.com/rex/docs),
  from Superlogical, is a terminal and multiplexer built on Ghostty's
  engine, in beta on macOS since 2026-10-05, and its Linux server with
  testers since late October. Its server API covers what the helper asks
  of tmux: start a terminal running a command in a folder, type into it,
  close it, and push events for its exit code and its program status (OSC
  7501, which tmux blocks; see
  [tmux#5713](https://github.com/tmux/tmux/issues/5713)). Its IDs are never
  reused, so a stale ID can't reach another terminal. Missing: a documented
  way for Emacs to attach to a terminal and stream it, as tmux-control does
  with control mode. Rex's stream starts with a snapshot in Ghostty's own
  format, and `rex block stream` isn't implemented: asked for in the beta
  on 2026-10-21, and still so on 2026-10-26 ([validation](validation.md)).
  Look again once Emacs can attach, or once tmux turns down OSC 7501 for
  good.
- **zmx and Ghostel in place of tmux.** [zmx](https://github.com/neurosnap/zmx)
  keeps each task's terminal in a small daemon of its own and redraws it
  from Ghostty's engine when you attach. Emacs would show a task as a plain
  Ghostel terminal running `zmx attach`, through `ssh -t` for a remote host,
  with no Eat and no tmux-control. The draft
  [#78](https://github.com/csheaff/roost/pull/78) tried it on 2026-10-20:
  links, Shift+Enter and program status worked without patches, and remote
  terminals shared one SSH connection, but zmx 0.8.1 isn't ready. It used
  less Emacs CPU too, but for terminals you can see tmux-control 0.8.3
  closed that gap (see Ghostel, above), so speed is no longer the reason;
  zmx's own readiness is what decides it. Look again
  once a zmx release keeps the whole scrollback when you reattach
  ([zmx#296](https://github.com/neurosnap/zmx/pull/296)) and shows a task
  started with nothing attached (fixed on zmx's main), and once an upgrade
  leaves running sessions reachable, or at least fails fast: today `kill`
  and `attach` hang against a daemon of another version.
- **herdr-core in place of tmux.** [herdr-core](https://github.com/herdrdev/herdr-core)
  (`hc`), split out of herdr on 2026-10-16, keeps each task's terminal in
  a background process with a documented API, answers the agent's status
  probe (OSC 7501) itself and keeps what it reports. Emacs would show a
  task as a Ghostel terminal running `hc attach`, through `ssh -t` for a
  remote host, with no tmux-control or Eat. The draft
  [#180](https://github.com/csheaff/roost/pull/180) tried it on 2026-10-29,
  on a Mac and on a Linux host over SSH: status came through with no relay
  and nothing attached, links and the whole scrollback survived a
  reattach, a dropped connection came back on its own, and an update left
  running agents alone. Not taken up: herdr-core is at 0.1.14 with a
  preview API, and no feature needs it. The relay covers status under
  tmux, and Ghostel can come to tmux-control (see Ghostel, above). It
  also starts every terminal at 200×120, so the agent's first redraw
  leaves copies in the scrollback, and on Linux it turns on systemd
  lingering for you without asking. Look again once it has a stable
  release, or when Roost needs something only it gives.
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
- **Files Git ignores in a task's worktree** go uncounted. Merging,
  retiring or discarding the task deletes them with the worktree, such as
  an edited `.env` or an agent's `notes/`, and the discard question says
  nothing about them. Ways out, smallest first: count them in the discard
  question and before retiring, as `git status --ignored=matching` lists
  them, a folder such as `node_modules/` as one, and leaving out the files
  `.worktreeinclude` copied that are still as copied; keep them, moved
  beside Roost's state for a while, rather than delete them; or refuse to
  retire while any differ from the primary checkout's, and offer discard.
- **An integration branch rewritten under a task**, as by a reset or a
  forced pull: merging the task brings back what the branch dropped, since
  the task's branch still has it, and a task with no commits of its own
  can't retire, being told to merge first. The smallest fix: when the
  commit a task started from is no longer on its integration branch, but
  that branch's reflog shows it was since the task started, refuse to
  merge, saying to rebase the task onto it (`git rebase --onto main
  START`), and let such a task retire if its own commits are merged.
- **A task started while the primary checkout is in the middle of a
  rebase or bisect** gets no branch to merge into, as from a detached
  HEAD, so it can only be discarded or forgotten. Starting one could
  instead refuse, naming the rebase, or take the branch being rebased.
- **Discarding a task another is stacked on** counts none of its commits
  as lost, since the other task's branch holds them, and merging that task
  later brings them into the branch you merge into. The discard question
  could name the tasks whose branches keep them. A stacked task's `ahead`
  also counts the commits it started from until the task under it merges.
- **A moved worktree** shows as gone in the task panel, which offers `x`
  and `X`; `x` then names the command that moves it back. The listing
  could say where it is, and the panel say so.
- **Partial clones** (`--filter=blob:none`): a full listing fetches the
  file contents it lacks from the remote to tell conflicts, without the
  time limit of Roost's other network calls. `GIT_NO_LAZY_FETCH=1` (Git
  2.44) on its reads would keep listings local, saying conflicts are
  unknown instead.
- **A bare repository with worktrees**, a common layout, can't start
  tasks: Roost takes the primary checkout for the repository, and a bare
  one has none.

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
  (`to merge`, `ci failed`, `comments`), whether or not the agent watches;
  fixing what it finds is the agent's.
- **`n` picking by a reckoning of its own.** `n` keeps a plain order,
  permission requests first, and says where it went and why rather than
  choose more cleverly out of sight. In a rescue-robot simulation, a key that chose the next robot for
  the operator added time to each visit, as operators caught up with a
  robot they hadn't picked, raised no score, and was the mode two thirds
  of them liked least
  ([Crandall et al. 2011](https://faculty.cs.byu.edu/~crandall/papers/Crandall_tsma2011.pdf)).
- **Predicted finish times.** Agents' run times vary too much to predict,
  and operators given probabilistic predictions of their schedule did
  worse than those given none
  ([Cummings and Mitchell 2005](https://doi.org/10.2514/6.2005-7060)). How
  long a task has worked or waited is certain, and Roost shows it.
- **Generated recaps as the main view.** Roost quotes the agent's own reply
  and lists what it changed, for Magit to show. ParallelPilot's
  model-written logs were its least valued part, below the live status
  view ([ParallelPilot](https://arxiv.org/html/2609.33113v1)), and agents'
  accounts of their own work are often wrong: claiming a success that
  didn't happen was nearly a quarter of the misbehaviour found in 20,574
  sessions ([How Coding Agents Fail Their Users](https://arxiv.org/abs/2605.29442)).
- **A "safe to merge" verdict, or merging on green.** Roost shows what a
  merge would rest on and leaves the decision, and the merge, to you. Aids
  that choose an action cost most when they're wrong, more than aids that
  only inform
  ([Onnasch et al. 2014](https://depositonce.tu-berlin.de/items/7df9879f-d77b-4f2b-8760-f0e3d174ca67/full)),
  and a verdict beside the evidence would be read in place of it.
- **A cap on how many agents you run.** No study gives a number: it
  depends on how long your agents run alone and how long their work takes
  to judge. `M-x roost-workload` shows how long yours waited on you, to
  find your own.
- **A docked review column.** Magit, opened with `r`, stages and takes
  notes; see [the Orca comparison](orca-comparison.md#review-notes-and-staging-in-magit).
- **Built-in browsers and design modes** (Orca, cmux, Superset), **a kanban
  view** (Org's agenda instead), and **scheduled runs** (Orca, Codex,
  Superset), which need something always running; cron on the host does
  that.
- **A container per task**, for now (agent-deck, workmux). Each container
  needs a copy of the agent's login, whose refresh tokens rotate, so copies
  sign each other out; a way for hooks inside it to report status out; and
  the repository's Git metadata mounted at the same path, with its hooks and
  config read-only. Use the agents' own sandboxes instead, or a VM reached
  over SSH ([Sandboxes](manual.md#sandboxes)).
- **Tasks in vendor cloud agents** (Claude Code on the web, Codex cloud).
  Their machines offer no SSH or terminal to attach to, so Roost meets them
  at the branches they push: fetch one and start a task from it with
  `C-c C-b` in the draft.

## Prior art

Surveyed 2026-10-11 from documentation and READMEs; Orca was also used
hands-on (see the [comparison](orca-comparison.md)). New ideas show up first
in changelogs.

| Project | What it is | Worth a look |
| --- | --- | --- |
| [Orca](https://www.onorca.dev/) ([changelog](https://www.onorca.dev/changelog)) | Desktop app: a worktree per task, SSH hosts, a phone app | Usage meters, automations, several attempts per prompt, native chat |
| [herdr](https://herdr.dev) | Terminal workspace that keeps agents' terminals in a background server; SSH machines. Split in October 2026 into [herdr-core](https://github.com/herdrdev/herdr-core), the server, and a desktop app | [Agent CLI and socket API](https://herdr.dev/docs/agent-automation/), [session restore](https://herdr.dev/docs/session-state/) |
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
| [zmx](https://github.com/neurosnap/zmx) | Terminal sessions kept by a daemon each, redrawn from Ghostty's engine on attach | Session labels, `zmx send`, `zmx history`; tried in [#78](https://github.com/csheaff/roost/pull/78) |

[awesome-agent-orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators)
tracks about 250 more; its terminal section is closest to Roost.
