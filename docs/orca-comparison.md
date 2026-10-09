# Orca and the Roost core workflow

Hands-on comparison on 2026-10-03 with the installed macOS Orca **1.4.219**.
[Orca](https://www.onorca.dev/) was explored using a disposable local repository;
Roost was exercised in native Emacs with an actual Claude task over SSH.

## What made Orca useful

The workspace gives a task a concrete home: project, starting branch, isolated
worktree, agent terminal, supporting terminal, and source-control review. Its
creation dialog makes the project and base branch visible. Creating a workspace
while another is selected defaults to the project branch; the parent-workspace
option describes sidebar nesting separately.

In the disposable workspace, splitting a terminal opened a shell in the same
worktree. After changing a file there, Source Control showed the changed file,
its real diff, and the workspace branch relative to `main`. Review and commit
controls were close to the terminal. This continuity matters more for the core
workflow than reproducing every panel.

The workspace menu also exposes human workflow states (Todo, In progress, In
review, Done), sleep and deletion. Those controls were inspected, not validated
end to end. The existing Claude configuration was left alone, and the agent was
cancelled at startup; actual Claude editing and permissions were tested in Roost.

## The changes retained in Roost

| Workflow need | Roost behavior |
| --- | --- |
| An independent task by default | New tasks use the primary checkout's current branch, including when invoked inside another task. A prefix argument defaults to an explicit fork from the current task's committed `HEAD`. |
| A useful shell near the agent | `roost-shell` creates or reuses a supporting pane in the task worktree, shows both panes, and selects the shell. Both panes share the task window's lifecycle. |
| Commands follow the work | Dashboard row, terminal pane, worktree directory and perspective identify the task. Manual perspective switches follow the corresponding task; unrelated workspaces do not silently target the last one. |
| Clear context and a way to finish | `roost-task-info` shows project, agent, task branch, starting ref, integration target, and review/finish actions. `roost-files` opens the worktree. The dashboard includes the project. |
| Review before completion | Magit handles staging and commits. Merge/retire checks both checkouts, merges committed work into the recorded integration branch, then removes the task resources. Agent `ready` remains distinct from reviewed work. |

Native use found that creating a server-side shell alone did not make both panes
visible in Emacs. Tiling is now explicit and idempotent. It also found that
process callbacks could restore focus after selecting the shell. Shell focus is
applied after tiling settles, with guards for subsequent navigation.

Each agent (Claude Code, Codex and the experimental Pi) has a small host-side
adapter for command validation, launch/resume arguments and hook
interpretation, while Git, SSH and tmux lifecycle operations stay outside it.
Older Claude records still resume.

## Later changes from using Roost daily

A review pass on 2026-10-04 used Roost for real parallel work and brought it
closer to Orca's surfaces where that helped:

| Orca | Roost |
| --- | --- |
| A creation dialog with project, base branch and prompt | A draft buffer with clickable fields, known projects and a multi-line prompt |
| A sidebar of workspaces with agent status | A dashboard grouped by host and project, with a status summary and Git changes; since 2026-10-04 also a pinned sidebar (below) |
| Base branch drift | Commits ahead and behind the integration branch; `u` merges it into the task, and the agent can resolve conflicts |
| Delete, with an explicit force waiver | Retire for finished work; forget drops only Roost's record and never touches Git |
| Branch prefix setting | `roost-branch-prefix` |
| Pull requests from a workspace | `P` drafts one from the agent's commit message and creates it with `gh` on the task's host; `P` again pushes review fixes; `x` retires after a squash merge and deletes the branch |
| Issue imports | `C-c C-t` in the draft starts from a GitHub issue, and the pull request closes it; `roost-new-task` on an Org heading, an agenda line, or a region starts the prompt, and the heading then stands for its task |

## The pinned layout, used end to end

Orca keeps three columns on screen: workspaces on the left, the agent's
terminal in the middle, and the workspace's files, source control and checks
on the right. On 2026-10-04 Roost gained the same shape, and two Claude Code
tasks were then taken from creation to merge in it (see
[validation](validation.md)).

| Orca | Roost |
| --- | --- |
| Left sidebar: projects and their workspaces, each with a status dot and an unread marker | `roost-sidebar-mode` (`b`): tasks grouped by host and project, a status dot, how many wait for you; a finished agent you have seen turns grey |
| Always there by default | Opt-in, since an Emacs package that claims a column of every frame should be asked to; one line in your configuration keeps it |
| Right sidebar: Source Control with the changed files and their diffs, live | The task panel: the agent's latest reply, the changed files, kept current, each opening its diff in Magit, commits ahead and behind, the pull request's review and checks, and every action. Staging and committing stay in Magit (`r`) |
| Checks tab | Pull request checks as passing, failing and pending counts in the panel |
| Agents tab: past sessions to resume | `s` resumes the task's own conversation; there is no history browser |
| Panels collapse by hand | The panel steps aside by itself when the terminal would drop below 80 columns, and comes back with room; `q` and `I` turn it off and on |

Using it found what a screenshot would not. Changes went stale while agents
worked, because background polls skip Git; Roost now measures a task whenever
its agent reports an event, a Git command such as your own commit touches its
worktree, you save a file there, or Magit refreshes it. Read replies kept
counting as waiting. Magit could open inside the panel's window. These are
fixed.

The panel first gave only a count of changed files; it now lists them, as
Orca's Source Control does, and each opens its diff in Magit.

What Orca still does better, in order of how much it matters day to day:

1. **Diffs in place.** Orca shows a file's diff inside the right column;
   Roost opens it in the main area, in Magit, where it can be staged (and,
   since 2026-10-09, annotated for the agent; see below).
2. **Width.** Three columns need about 156 columns. On a laptop frame Roost's
   panel steps aside, which keeps the terminal usable but loses the third
   column; Orca's toggles have the same limit.
3. **Automations and usage limits.** Orca runs agents on a schedule and shows
   Claude and Codex usage in its status bar. Roost has neither.

## Review notes and staging, in Magit

Two things in Orca's right column came up as reasons people like it (Orca
1.4.219's bundled code, read on 2026-10-09):

- **Staged and unstaged files side by side**, staged with a click. Staging
  doubles as approval: once a file is staged, anything its agent changes
  later shows as unstaged on top. Orca stages whole files and folders only.
- **Notes on diff lines** ("Add note for the AI"), on a line, a range or a
  file, kept per worktree until sent. Sending pastes them into the
  worktree's agent as `File:`, `Line:` and `User comment:` blocks, after
  waiting for the agent to be idle and never into a permission prompt.

Roost does both in Magit, where you review anyway, rather than in a column of
its own. Magit already shows staged, unstaged and untracked changes and
stages hunks and single lines, not only files. A docked Magit would have to
refresh itself while the agent works, and a refresh starts 12 to 56 Git
processes (276 ms for a full status locally), each a round trip over TRAMP;
summoned with `r`, it refreshes only when you ask.

| Orca | Roost |
| --- | --- |
| Source Control: staged, unstaged and untracked files, stage per file | Magit's status (`r`), staging files, hunks or lines; it names the task and folds in the agent's latest reply |
| Notes on a line, a range or a file | `;` in Magit on a task: on the line at point, the region's lines, or a file's name. Notes show under their lines in every Magit buffer on the task, follow their line when the agent edits above it, and survive restarts |
| Send notes: this file, or all unsent | `@` (or `e`) drafts a prompt holding every unsent note, quoting the lines they are about; sending it clears them |
| The diff of a whole file in the editor area | `=` shows the whole file with its changes, as a Magit diff you can still stage from |

Mobile access, embedded browsers, trackers other than GitHub, workflow boards
and sparse checkouts remain outside Roost. Emacs already supplies
file editing, project navigation and Git review. Roost's job is to make those
tools belong to the same durable task.

See [validation](validation.md) for the actual development cycle and limitations.
