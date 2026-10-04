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
| A sidebar of workspaces with agent status | A dashboard grouped by host and project, with a status summary and Git changes |
| Base branch drift | Commits ahead and behind the integration branch; `u` merges it into the task, and the agent can resolve conflicts |
| Delete, with an explicit force waiver | Retire for finished work; forget drops only Roost's record and never touches Git |
| Branch prefix setting | `roost-branch-prefix` |
| Pull requests from a workspace | `P` drafts one from the agent's commit message and creates it with `gh` on the task's host; `P` again pushes review fixes; `x` retires after a squash merge and deletes the branch |
| Issue imports | `roost-new-task` on an Org heading, an agenda line, or a region starts the prompt |

Mobile access, embedded browsers, issue-tracker imports, workflow boards and
sparse checkouts remain outside Roost. Emacs already supplies
file editing, project navigation and Git review. Roost's job is to make those
tools belong to the same durable task.

See [validation](validation.md) for the actual development cycle and limitations.
