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

[Toward 2027](#toward-2027) asks something else: what Roost would be if
agents carried more of each change themselves, and people mostly said what
they wanted and judged the evidence.

## Most likely first

Small, and probably worth the most.

- **Ready for MELPA.** Keep Roost passing MELPA's checks, with
  [the recipe and its status](melpa.md) current, and send it once
  ghostel-tmux is on MELPA and people ask for Roost there. Features don't
  wait for it.
- **Your phone, through Claude Code's Remote Control**, is in Roost now:
  `roost-remote-control` starts each Claude task with `--remote-control`
  and `--name`. Until Roost keeps a presence file
  ([Worth trying](#worth-trying)), the Claude app also notifies you while
  you're at Emacs. Herdr, Orca, Superset, cmux and agent-deck each built a
  phone app for this.

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

- **One hand and a voice, the rest of the way.** From the UX review of
  2026-11-01 ([validation](validation.md)): a `+` in the sidebar's header
  line offering the recent projects as a menu, for when many tasks push
  "Start a task in" out of sight; a discard that takes its name as
  dictation gives it, with capitals, spaces and a full stop; Roost's task
  menu in a task's terminal, where most time goes; and a line in the
  manual that answering an agent's question takes a real key (Enter takes
  its default), which Roost doesn't press for you.
- **What changed since you looked, beside a long name.** From the UX
  review of 2026-11-09 ([validation](validation.md)): the sidebar says
  "3 files changed" only beside a task's whole name, so at 30 columns a
  name over 13 characters says nothing. A dim mark at the row's end, as a
  status has in a narrow sidebar, would say there is something.
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
- **Attempts compared with Ediff** are in Roost now: `=` on an attempt
  lists every file the attempts changed, and `RET` on one compares two
  attempts' copies of it in Ediff. Still to try: taking hunks from each
  into one of them, rather than picking one.
- **An attach command for other terminals** is in Roost now:
  `M-x roost-copy-attach-command` copies the `ssh -t … tmux attach` that
  reaches a task's real terminal, for a phone's SSH app or another
  machine, for every agent.
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
- **Several attempts at one prompt** are in Roost now: a count, or several
  agents, in the draft (`C-c C-x`) makes sibling tasks; you compare them,
  merge one, and finish the rest yourself. From Orca ("fan one prompt
  across 5 agents"), dmux and workmux (`-a`, `-n`). Of the ideas here, it
  and [agents that start tasks](#exploring) add the most to review without
  making any of it quicker to judge, so it fits where attempts are cheap to
  compare, as with Ediff (above).
- **A fork that goes on with the conversation** is in Roost now: `C-u c`
  forks a task's commits and uncommitted changes, and its agent goes on
  from a copy of the task's conversation, as Claude Code's
  `--resume ID --fork-session`, `codex fork` and Pi's and OpenCode's
  `--fork` make one; `C-c C-f` in the draft starts a new conversation
  instead. It fits one case: a long investigation that ends at two
  plausible fixes, each worth trying with all the agent has learned. With
  Claude Code 2.1.312, a fork finds a conversation recorded in another
  folder, and its hooks report the fork's own session; a sentence Roost
  puts before your prompt keeps the agent to its new worktree; with
  2.1.322 a fork named a word its task had been told
  ([validation](validation.md), 2026-11-11). From agent-shell's
  `agent-shell-fork` and agent-deck's forking.
- **Better task names.** Names come from a prompt's first words, and `R`
  renames a task. Claude Code titles its sessions itself, in an `ai-title`
  line of the transcript (or the name its `/rename` gave), which `R` could
  offer, doing nothing for an agent that keeps no title; Pi's sessions
  hold none, and Codex's CLI is unchecked. A model call on the host is
  the other way. From dmux, workmux (`-A`), Orca and agent-deck.
- **Review notes from file buffers**, for diff-hl users who review in the
  file rather than in Magit.
- **Ghostel draws the terminals**, in Roost now, through
  [ghostel-tmux](https://github.com/dakra/ghostel-tmux), with the Kitty
  keyboard and graphics protocols and synchronized output
  ([validation](validation.md), 2026-11-15 and 2026-11-16). What is left
  is use, and what Roost reads of ghostel-tmux that is private: whether a
  client ended by a detach or a dropped connection.
- **Images in a task's terminal** are in Roost now for Pi, which Roost
  starts with `PI_IMAGE_PROTOCOL=kitty`. An image goes when Pi redraws its
  screen, as after a resize. tmux's main branch takes Kitty graphics from a
  program in a pane (2026-10-16) and draws them on a terminal that shows
  them (2026-10-29), in no release yet: 3.8 is the latest.
- **A second sign on the count, beside colour**, is in Roost now: the
  mode line's count has a mark while an agent asks, as `● Roost:2!`, and
  its help says how many ask. The sidebar's `2 waiting` still tells them
  apart by colour alone. From the
  [UX review of 2026-10-23](validation.md).

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
  would wait for your yes too. That part is in Roost now, with your yes at
  each task: an agent offers tasks you start (`roost-agent-offers`,
  [#203](https://github.com/csheaff/roost/issues/203)), and a conversation,
  which has no project, plans a piece of work as tasks in your projects,
  each waiting under it for you to open and start. What it may grow, if
  real offers ask for it, is reading the tasks an offer started and setting
  an offer aside for later. Codex, OpenCode and Pi have the tools too. A
  fuller build is on branch `agent-offered-tasks`.
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
  7501, which tmux blocks for now; see Known gaps). Its IDs are never
  reused, so a stale ID can't reach another terminal. Emacs can attach
  now: [rexel](https://github.com/dakra/rexel) (GPL-3) shows each Rex
  block as a Ghostel buffer, loading the snapshot in Ghostty's format
  that the stream starts with.

  Run on 2026-11-22 through the checks the zmx entry below lists, with
  rexel 0.6.0 and Ghostel 0.66.0 in batch Emacs, against a scratch Rex
  server on the Mac (0.1.0-preview.21) and one on the Linux host
  (snapshot 2506, through an ssh-forwarded socket). All passed, three
  runs each:
  - A block started from the CLI with nothing attached showed in full on
    the first attach, and a reattach kept the whole scrollback (60 of 60
    lines) and both OSC 8 links.
  - A dropped connection, locally or by a `kill -9` of the ssh tunnel,
    kept the buffer; rexel redialled by itself and was live again 2 s
    after the tunnel came back. Bringing the tunnel back is left to you.
  - Narrowing, widening and a narrower reattach each reached the
    program, and a long line reflowed whole.
  - A real Claude (2.1.330, Haiku) started with nothing attached reported
    its status anyway: Ghostel showed idle on the first attach, then
    working and done for each turn, typed with `rex send`. Replies and
    links survived a reattach, and it redrew at 34 and 79 columns.

  Two clients take turns at the size: attaching or selecting a window
  takes the block, typing doesn't, the other client's mode line reads
  "Sized by another client", and when the owner leaves the size goes back
  to the client left. Rex logged no crash. What still stops it is Rex
  itself: its server is for beta testers only and states no licence.
  Look again once Rex is open to everyone.
- **zmx and Ghostel in place of tmux.** [zmx](https://github.com/neurosnap/zmx)
  keeps each task's terminal in a small daemon of its own and redraws it
  from Ghostty's engine when you attach. Emacs would show a task as a plain
  Ghostel terminal running `zmx attach`, through `ssh -t` for a remote host,
  with no tmux. The draft
  [#78](https://github.com/csheaff/roost/pull/78) tried it on 2026-10-20:
  links, Shift+Enter and program status worked without patches, and remote
  terminals shared one SSH connection, but zmx 0.8.1 isn't ready.
  Speed is not the reason: zmx's own readiness is what decides it.
  Run again on 2026-11-22 with zmx 1.0.1 and Ghostel 0.65.0 on a Mac,
  in batch Emacs at 79×23 with 60 lines of output and two OSC 8 links,
  one scrolled into scrollback and one on screen; zmx 0.8.1 beside it
  for comparison. Each check passed in each of three runs:
  - A reattach keeps the whole scrollback, 60 of 60 lines; 0.8.1 kept
    38, losing a screenful.
  - A task started with nothing attached shows in full on the first
    attach; 0.8.1 showed a blank screen.
  - Both links still open after a reattach; 0.8.1 kept their colour
    but not the links.

  Two gaps are left:
  - A client of another version: against a 0.8.1 session, 1.0.1's
    `list` says "unreachable" at once and `send` fails with an error,
    but `kill` hangs and `history` waits 5 s and prints nothing. 1.0
    freezes the protocol, so this should matter only across the 1.0
    line; the helper would still check versions before a kill.
  - Each session that ends on macOS leaves a crash report, all twelve
    of the run's from 1.0.1, the abort in
    [zmx#294](https://github.com/neurosnap/zmx/issues/294), though 1.0.1
    has that issue's proposed fix. Sessions worked regardless.

  A real Claude (2.1.330, Haiku) did the same, in four turns, each
  typed with `zmx send`. Started with nothing attached, it showed on the
  first attach, and both replies and their link came back after a
  reattach with no second banner. It reported no status, since zmx
  answers its probe while nothing is attached, so Roost's relay would
  still be needed. Attached at the start, it reported idle, working and
  done to Ghostel, and kept reporting after a reattach.

  On a Linux host (x86_64), shown on the Mac through `ssh -t`, the same
  checks passed in each of three runs, each attach drawing in under
  half a second. A session started over an ssh with no terminal
  outlived that ssh. After a `kill -9` of the ssh under a terminal,
  Ghostel closed the buffer, as in #78, and a reattach brought back the
  whole scrollback and both links. Typing through ssh reached a shell
  session. The host's daemons shut down cleanly, with no crash, so the
  crash reports are the Mac's alone.

  Resizing, tried the same day on the Mac and on the Linux host, with
  the same results on both. Narrowing a window from 79 to 34 columns
  and widening it back reached the program each time, and a 150-column
  line reflowed whole. A reattach in a narrower window gave the session
  that width. A real Claude redrew its screen at 34 columns and back at
  79, answered a turn while narrow, and kept every reply through a
  reattach at 33. Narrowing left one more copy of its banner in the
  scrollback, as in #78; widening and reattaching left none.

  Two clients at different widths share one size: the one that last
  typed sets it, and it stays after that client leaves. A 48-column
  client drew a 29-column session narrow but whole; a 29-column client
  wrapped a 48-column session. With tmux, Roost takes the size back for
  the window you are looking at; under zmx it would need a way to do
  that without typing into the agent, and zmx has no command for it.

  Look again once a release leaves no crash reports on macOS.
- **herdr-core in place of tmux.** [herdr-core](https://github.com/herdrdev/herdr-core)
  (`hc`), split out of herdr on 2026-10-16, keeps each task's terminal in
  a background process with a documented API, answers the agent's status
  probe (OSC 7501) itself and keeps what it reports. Emacs would show a
  task as a Ghostel terminal running `hc attach`, through `ssh -t` for a
  remote host, with no tmux. The draft
  [#180](https://github.com/csheaff/roost/pull/180) tried it on 2026-10-29,
  on a Mac and on a Linux host over SSH: status came through with no relay
  and nothing attached, links and the whole scrollback survived a
  reattach, a dropped connection came back on its own, and an update left
  running agents alone. Not taken up: herdr-core is at 0.1.14 with a
  preview API, and no feature needs it. The relay covers status under
  tmux, which has agreed to keep that status itself (see Known gaps), and
  Roost draws with Ghostel already. It also starts
  every terminal at 200×120, so the agent's first redraw
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
- **The setup command run ahead.** A task takes a worktree made ahead in
  under half a second, then waits for `roost-setup-command` in its
  terminal, as long as `npm ci` takes. Running it in the worktree made
  ahead would have the agent start at once. Left unbuilt (#312), for what
  it would change: the command would run with no task yet, so with no
  `$ROOST_TASK_ID` and no branch; in a folder Git moves when a task takes
  it, which breaks what records its own path, as a Python virtual
  environment or a Bazel output base does; out of your sight, its output
  in no terminal; and on a yes you gave for an earlier task, where Emacs
  asks about a command set in `.dir-locals.el` each time. If someone with
  a slow setup asks: an option a project turns on for itself, off by
  default; only for a command trusted for good (your own configuration, or
  `safe-local-variable-values`); the worktree made anew, and set up again,
  when the commit it is made at moves; and a setup that fails ahead left
  to the task's terminal, where you see it.

## Toward 2027

A direction rather than a list, written on 2026-11-28. By late 2026, talk
among people who build with agents expected agents to carry more of each
change: plan it, write it, run its tests and open its pull request, while
people say what they want, judge the evidence and decide what ships. Roost
today helps you watch agents' terminals and step in. In this direction it
would hold what you asked for, have the work checked by someone other than
the agent that did it, and act within limits you set, also while you're
away. You would decide a merge on that evidence, and talk to an agent in
its terminal when you step in, rather than watch the terminal to judge the
work. Most of it reverses an entry under [Not planned](#not-planned) or the
advice on where features stop, so each piece says what it gives up. None of
it is decided.

What stays:

- Agents from several labs, which counts for more once one checks
  another's work.
- The agent's own terminal as the way to talk to it.
- The models, crash tests and sweeps, which matter more once Roost acts
  while nobody watches.
- Deleting work only when you discard it. Anything Roost does on its own
  can be undone, and is logged.

The pieces, each building on those before it:

- **Goals above tasks.** A goal holds what you want, how to tell it's done
  as commands that pass or fail, a budget, and the tasks that work on it,
  in waves. The helper keeps its record, so it outlives the conversation
  that planned it. A conversation's offers are its start
  ([Agents that start Roost tasks](#exploring)), and branch
  `orchestrated-waves` takes them on to waves.
  What you write and review becomes the goal more often than the code.
- **Evidence from someone other than the author.** When a task's agent says
  it's done, Roost checks. First what no account can argue with: the
  project's check command in a clean worktree (from
  [Scripts beyond setup](#worth-trying)), mutation testing on the changed
  lines, to catch tests written to pass, and the change's size and the
  risky paths it touches. Then a reviewer agent, reading only, given the
  goal rather than the author's account: from another lab where you have
  one, or else the same agent in a fresh session. Copilot's reviews of
  Roost's own pull requests give a first sign: from 2026-10-04 to 11-27,
  652 findings on 169 pull requests, after the review asked for before
  each, of which the authoring agent fixed 610 and declined 32. Many were
  on crash, race and lost-work paths, such as a forget that would delete
  the worktree it promised to leave. But the agent that fixed them also
  judged them, so 610 is its count, not a reader's; many were rare races;
  and nothing compared a fresh session of the same agent, so whether
  another lab adds more is still open. What they find goes under what a
  merge rests on, in the task panel, facts first and the reviewer's words
  after, since a reviewer's account can be wrong too. Agents' accounts of
  their own work often are
  ([How Coding Agents Fail Their Users](https://arxiv.org/abs/2605.29442)),
  so the check is someone else's. It costs a second agent's tokens for
  each task, and Roost starts programs of its own.
- **A helper that stays running.** The helper runs for each request now,
  and Emacs decides when to tell an agent or wake a conversation, so
  nothing moves while Emacs is closed. A service on each host (a systemd
  user unit, a launchd agent) would run the waves, retry after a failed
  check and tell agents it's their turn. Emacs would be its main client
  among others, through a socket: a `roost` command inside tasks, a phone,
  teammates. A pull request left to its agent already wants this
  ([Not planned](#not-planned)). It is the largest change to how Roost
  works, and each model in `test/formal` would be redone.
- **Limits in place of a yes at each step.** A project says what may happen
  without you, by risk: docs, tests and small dependency bumps merge once
  their checks and review pass; most changes wait for you, as now; and
  paths on a project's list or in CODEOWNERS, such as CI, authentication
  or releases, also need the reviewer's findings answered. A budget per
  goal, in tokens, money and time, stops its tasks once spent. This
  reverses the entry on merging on green, but Roost would still show no
  "safe" mark: the tier and the evidence, with the limits acting on them,
  so the evidence stays in front of the decision
  ([Onnasch et al. 2014](https://depositonce.tu-berlin.de/items/7df9879f-d77b-4f2b-8760-f0e3d174ca67/full)).
  The paths come from [Marks for risky changes](#when-a-merge-is-your-turn).
- **Trust from how work turned out.** How often each agent's merged work,
  by kind of task and by tier, was reverted or fixed again within some
  days ([How often merged work came back](#exploring)). An agent that keeps
  getting a path wrong stops merging there on its own. Without this, what
  agents may do only grows, and unchecked work feeds more agents.
- **Hosts as a pool, each task sandboxed.** A task goes to whichever host
  has room: this machine, SSH hosts, Coder workspaces
  ([Exploring](#exploring)), cloud machines. Each runs in a container or
  VM, with the agent's login lent through a broker on the host rather than
  copied in, since copies of rotating tokens sign each other out. This
  reverses the entry on a container per task.
- **Work that arrives on its own.** A ticket
  ([#216](https://github.com/csheaff/roost/issues/216)), a failed check on
  main, an error tracker's report or a failing eval becomes a proposed
  goal, in a list for you, or a project's limits, to start. It needs the
  running helper, and goes further than agents that start tasks.
- **Teams.** Goals and their evidence that others read and review, with
  review by someone other than the person who started the goal. Roost is
  one person's Emacs now; this needs the running helper and a record of
  who did what.

What would stop: trying other terminals in place of tmux (Rex, zmx,
herdr-core), whose notes stay under [Exploring](#exploring), since tmux
does what's needed; and more work on noticing which agent needs you, which
matters less once the helper takes many of those turns itself.

An order through 2027: goals and evidence first, from what conversations
already do; then the running helper, limits and budgets; then the pool,
sandboxes and work that arrives on its own; then teams and trust.

The risk is that the labs run their own agents side by side, as Claude
Code's background sessions already do ([Exploring](#exploring)). What they
are unlikely to build: agents from several labs, on your own machines,
through Git, checked by someone other than the author, with the real
terminal there to step into when a decision needs you, run by a tool
model-checked not to lose your work. Roost would stay there rather than
grow toward Orca's breadth.

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
  tmux could make the relay unnecessary: on 2026-10-30 its maintainer
  agreed to keep each pane's latest report, readable as the formats
  `program_state`, `program_name` and `program_message`, and asked for a
  pull request ([tmux#5713](https://github.com/tmux/tmux/issues/5713)). On
  a tmux with it, Roost could read status from tmux; an older tmux would
  keep the relay.
- Codex reports only whether it works, waits on you or idles, and works
  between turns too, while its servers start or a command it left running
  runs. So its hooks say when a turn starts and ends, and with
  `roost-program-status` on, a turn that starts before you trust them, as
  a new task's first one can, shows `ready` while Codex works.
- A Pi extension's dialog names only its title ("Run this command?"), not
  what it asks about, so that is all the request shows.
- `/` searches what Claude Code, Codex and Pi keep of a task's
  conversations, as files of one message a line. OpenCode keeps its
  sessions in a store of its own, which Roost doesn't read, so its tasks'
  conversations are not searched, and the results say so.
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
- **Submodules fetched again for each task**: Git clones a linked
  worktree's submodules under `.git/worktrees/TASK/modules/`, apart from
  the primary checkout's, so each task fetches them anew. `--reference`
  to the primary checkout's clones would save that time and room, as long
  as removing the worktree can't harm them. And a submodule only the
  task's branch has is left out while the primary checkout has others
  initialized, as Roost can't tell it from one you deinitialized.

## Not planned

- **Answering the agent's prompts from Roost** (approval inboxes, approve
  keys). The agent's own terminal stays the way you talk to it, so its
  menus and new features work on day one. Calyx and octomux have inboxes.
- **Fixing a pull request for the agent, or reading it what a reviewer
  wrote.** Fixing what a failed check or a review finds is the agent's, and
  so is reading it. Roost says whose turn it is, and for a pull request you
  left to its agent (`L`, `roost-leave-pull-requests`) it says so to the
  agent, in one line of its own, with every agent alike. That was not
  planned here until 2026-11-14: it was left to each agent's own watcher,
  which in a terminal only Claude Code has, and only once you type `/loop`.
  An agent that does watch its own pull request starts within the two
  minutes Roost gives it, and is told nothing. What it may grow, if use
  asks for it: telling while Emacs is closed, which needs something always
  running on the host, and a model of it beside the others in
  `test/formal`.
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
