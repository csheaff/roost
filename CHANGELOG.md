# Changes

What each release changes, and what to do when upgrading. Newest first.

## Unreleased

Since 0.8.1:

- A task whose work is merged, through its pull request on GitHub or into
  the branch it merges into, says `merged` in the dashboard and sidebar, so
  you can see which tasks to retire without opening them. Roost now finds a
  pull request the agent opened itself from the task's branch, and asks
  GitHub about pull requests every two minutes, not only when you refresh
  the dashboard. Retiring a task whose pull request GitHub squashed no
  longer refuses for unmerged commits when the agent opened it. Nothing to
  do when upgrading.
- Search results fit their window, each message's line cut with an
  ellipsis, rather than running past its edge; `TAB` shows the rest.
  `RET` on a message from a task that is gone, or `TAB` on one its line
  already shows whole, says so, rather than repeating the message under
  it. Nothing to do when upgrading.
- The manual recommends tramp-rpc for remote hosts, with a setup to copy,
  and `roost-doctor` names it for a host whose Magit goes over a shell
  method. Magit opened a remote task in 0.4 s with it, against 3.6 s over
  `scp`. Nothing to do when upgrading, unless you want it.
- With tmux-control later than 0.7.2, a task's terminal split into panes,
  as with `t`'s shell, keeps its window tabs above the panes, and each
  pane's mode line names the task and keeps the rest of your mode line,
  such as Roost's count of waiting agents. To upgrade, update tmux-control
  too.
- Opening a task leaves the window alone when you show something else in
  it before the task's host replies, such as tmux-control's scrollback
  with `C-c C-e`: the reply put the task's terminal back in its place.
  Nothing to do when upgrading.
- Two tasks of one name in a project no longer look the same in the
  sidebar and the dashboard: each shows the start of its ID after its
  name, as the task picker and tab names already did. Nothing to do when
  upgrading.
- A task no longer goes back to what its agent did before, such as
  running or asking for permission, for a few seconds after its turn
  ends. A refresh that took a while could arrive after a newer one and
  put back its older state; while it lasted, the menu offered nothing for
  a task at rest, such as `x`. Nothing to do when upgrading.
- The dashboard's line for a host Roost can't reach fits the window, with
  the whole error on hover, rather than running off its edge. Nothing to
  do when upgrading.
- A new task's draft, the dashboard and search, opened from a task's
  terminal split into panes (as with `t`'s shell), open beside the panes
  rather than in the pane you are in. There, tmux-control took the window
  back when it next arranged the panes, and what you typed went to the
  terminal. Nothing to do when upgrading.
- With a tab per task, a task keeps its tab when you start another of the
  same name, whose tab has its ID after the name. Before, Roost then looked
  for the first task's tab under a name with its ID too, so that tab lost
  its panel and opening the task made a second one. Nothing to do when
  upgrading.
- `n` takes the tasks that ask for permission in turn. With three or more
  asking, it went back and forth between the first two. Nothing to do when
  upgrading.
- A task you open while answering a question, as a slow host replies,
  shows once you have answered, rather than taking the window you were
  typing in: your answer went to its agent's terminal. Closing a frame
  moves the sidebar's marker to the task of the frame you are left in. A
  task's panel leaves the latest reply to its terminal from the moment the
  terminal connects, rather than showing it until the next redraw. Nothing
  to do when upgrading.
- Stopping, retiring, merging or discarding a task gives its window back to
  what it showed before, but never to another task's terminal: stopping one
  task used to bring up another's, where `s` then resumed nothing. A
  dashboard heading cuts a long project path at its start, keeping the end
  that names the project, rather than running off the window. Discarding
  work not yet committed points to `r` to commit it, not `m`, which merges
  only commits. Nothing to do when upgrading.
- When `m` merges the task whose terminal is on screen, the panel and the
  sidebar's marker follow the task whose terminal Emacs shows in its place;
  before, no panel came back until you opened a task. Opening a task marks
  it in the sidebar at once, rather than when its host replies. Nothing to do
  when upgrading.
- Opening a task shows its terminal in place of another task's, rather than
  in a code or Magit window selected beside it, which left the other task's
  terminal on screen. With tmux-control later than 0.7.2, switching away from
  a task whose terminal is split into panes no longer leaves those panes
  beside the next task's, and they come back when you return. To upgrade,
  update tmux-control too.
- In the task panel, a task's status goes below its name when they don't
  fit on one line, rather than breaking after "for". Showing or folding the
  prompt or the latest reply leaves point on the button that takes it back,
  rather than in the text that moved, which the line highlight then covered.
  Nothing to do when upgrading.
- Without Magit, `D` says the diff needs it and that `r` opens the worktree
  in Dired, rather than failing to load Magit. Nothing to do when upgrading.
- A long prompt shown whole in the task panel folds up again: "Collapse
  prompt" sits above it, as "Collapse reply" does above a long reply.
  Nothing to do when upgrading.
- The task panel puts what to do next at its top, then the task's prompt,
  then the files it changed, those not yet committed first, under labels
  that say which. It reminds you that `;` in a file's diff writes a note for
  the agent. While the agent's terminal is on screen, the panel leaves the
  agent's latest reply and permission requests to it; elsewhere, as with
  `i` from the dashboard, it still shows them. Its list of every action is
  gone: `?` in the panel opens the same menu. Nothing to do when upgrading.
- Links in an agent's latest reply, in the task panel and in Magit, open with
  a click or `RET`, and a Markdown link shows only its text. In the agent's
  terminal, with tmux-control later than 0.7.2, `C-c C-u` opens a link it
  shows, and so does a click on a link the agent marks as one. Claude Code
  marks its links with tmux 3.4 or later, as in the pull request it names
  `#22`; before, those showed only their text, with no URL anywhere. To
  upgrade, update tmux-control too, and tmux to 3.4 for the marked links.
- With perspectives, a task's buffer list no longer offers the terminals of
  other tasks: one that reconnected in the background was added to
  whichever task you were in. Nothing to do when upgrading; switching
  tasks again or restarting Emacs clears those already added.
- A task's agent starts at the size of the window it opens in, not tmux's
  80 by 24, so its first output is no longer wrapped narrow and torn by the
  redraw when Emacs attaches. Tasks started earlier keep their history;
  nothing to do when upgrading.
- A pane you split off in a task's window closes when its program exits;
  only the agent's pane stays to show how it ended. Tasks started earlier
  change when resumed.
- Roost needs tmux 3.1 or later, as it always has: it sets options on
  panes, which tmux 3.0 can't. `roost-doctor` now says so.
  `C-c C-o` moves between the agent and its shell once tmux-control is past
  0.7.2.
- Prompts, replies and permission requests are set in `variable-pitch`
  (face `roost-prose`), which fits more of them in the panel and the
  dashboard; tables and code in replies keep the fixed-pitch font. A status
  word is coloured only when its agent can't go on without you or failed,
  plain while it otherwise waits for you, and dim the rest of the time; the
  dot keeps the colour. Actions and changed files are no longer underlined,
  and groups and sections are half a line apart. To keep the old look,
  make `roost-prose` inherit `default` and `roost-field` inherit `link`.
- `m` now squashes a task's work into one commit. Set `roost-merge-style`
  to `merge` for a merge commit, as before.
- Roost watches, counts waiting agents and notifies you only once you open
  it, unless your configuration turns on `roost-watch-mode`, as the install
  snippets now do; `roost-doctor` says which. While it watches, `C-c ?` in
  an agent's terminal, or in Magit on a task, opens the menu.
- Magit's status of a task lists the commits not yet merged (`Unmerged into
  main`), so work the agent committed has a place to be reviewed.
- Stopping, updating, merging and retiring a task with nothing to lose ask
  `y` or `n`; discarding work still has you type the task's name. A finished
  task's panel closes with it, and reading a task's panel counts as seeing
  its agent's reply. A permission request leaves out a leading `cd` into
  the task's worktree, and shows paths in it relative to it.
- The sidebar (`b`) and the task panel beside each terminal (`I`). The panel
  lists only what a task can do now and says what comes next; the command
  menu says so too, and greys out the rest. Like the sidebar, the panel is
  off until you turn it on: add `(roost-task-panel-mode 1)` to your
  configuration to keep it. Neither has a mode line: while you are in one,
  it shows the cursor (with its modal-editing shape) and highlights the line
  you are on in face `roost-selection`, which replaces
  `roost-sidebar-selection`.
- `/` searches the conversations of your tasks on every host, including
  tasks retired since: every word must be in one message, yours or the
  agent's, and tool output is left out. Each host searches its newest
  conversations first, for at most 20 seconds. Claude Code tasks only, for now.
  Hosts record each repository beside its worktrees, so a task retired
  after this release is shown under its project.
- Each task has a tmux session of its own, which ends with the task. Older
  tasks move to their own when resumed. `roost-session-name` is gone.
- `x` finishes a task: it retires one whose work is merged, or discards one
  whose work isn't (`roost-discard`), with the worktrees its agent made. `X`
  only forgets. `m` merges while your checkout is on another branch (Git 2.38+).
- A turn that failed while its agent waits shows as `error`. Errors, failed,
  crashed and exited agents count as waiting until you've seen them,
  and what you've seen is kept on the task's host, for your other machines and
  the next session.
- Keys follow Magit's: `h` and `?` open the menu, `i` a task's details (`?`
  before); `l` switches task. Roost polls every 15 s while Emacs isn't in
  front (`roost-watch-unfocused-interval`).
- `M-x roost-forget-host`; setup commands get the primary checkout in
  `$ROOST_REPO`; a notification click opens its task (terminal-notifier).
- Claude Code worktrees an agent makes for itself show in its task's panel.
- Review notes: in Magit on a task, `;` writes a note for the agent on a
  line, in a box that opens under it, and `@` sends your notes. With the
  mouse, click the `+` that shows beside the diff line under it (drag for
  more lines), and click a note (or `C-c ;` on its line) to edit it, send it
  alone or discard it. `'` goes to a note chosen in the minibuffer. `=` shows
  a whole file's diff. The status
  names the task and folds in the agent's latest reply. A draft prompt
  (`e`, or `roost-send-region`) now keeps what you have written and adds to it.
- A new task's project is the one you are in again, also in Dired or a
  shell; the picker adds `project.el`'s projects. A turn you interrupted, or
  whose permission you declined, shows as `interrupted` rather than `ready`.
  `u` on a task with uncommitted changes offers to have its agent commit and
  update, and `roost-merge-style` can squash a task into one commit. With no
  tasks yet, the menus grey out the task commands.
- With tmux-control newer than 0.7.2, switching sessions from a terminal
  (`C-c C-s`, next and previous session) opens that task in its workspace.
- `roost-claude-command` moved into `roost-agent-commands`, and
  `roost-use-perspectives` into `roost-workspace`; both still work.
- An agent keeps the hooks it was started with, so one started before this
  notices its own worktrees only after `K` and `s`.

## 0.8

0.8 adds GitHub issues as a starting point (`C-c C-t` in the draft), the
command menu (`h`, or `roost-dispatch` from anywhere), the mode-line count of
waiting agents, links between Org entries and their tasks, and one shared SSH
connection per host. It needs transient, which Emacs 29 includes.
`roost-dispatch` used to be an alias for `roost-new-task`; it now opens the
menu, where `c` starts a task.

## 0.7

0.7 needs tmux-control 0.7.0, which adds the public API Roost now uses. Update
tmux-control first: with straight.el or a Git checkout, pull it before Roost;
with `package-vc`, run `package-vc-upgrade` on tmux-control, then Roost. Then
restart Emacs. `M-x roost-doctor` flags an older tmux-control. 0.7 also adds
pull requests (`P`), the agent's latest reply in the dashboard, task panel
and notifications, prompts from Org entries and the region, and a push check
in `roost-doctor`. `D` now diffs a task's own changes since it last met its
integration branch, so updates from `u` no longer appear as the task's work.

## 0.6

0.6 declares tmux-control as a package dependency and adds `roost-doctor`,
tab-bar workspaces and Evil support. Stopping a task moved from `k` to `K`; `j`
and `k` now move between tasks in the dashboard.

## 0.5

0.5 defaults new branches to `roost/…` (formerly `codex/roost/…`; existing tasks
keep theirs). It replaces the minibuffer prompts of `roost-new-task` with the
draft buffer; called from Lisp with arguments, it still creates the task
directly. Retired task records are now deleted. Codex tasks started after
upgrading ask for one final hook review.

## 0.4 and 0.3

0.4 added Codex and Pi. 0.3 replaced the 0.2 Pi orchestrator registry.
