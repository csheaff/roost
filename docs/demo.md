# The README screenshots

The images are native captures of GUI Emacs on 2026-10-04, taken while Claude
Code (Haiku 4.5) worked on two small disposable projects: `notes`, a notes CLI on
the Mac, and `ledger`, an expense-ledger CLI on the SSH host `claylien`, each
agent in its own terminal with its normal permission prompts.

The capture Emacs was a plain configuration so that nothing personal distracts:
the stock `modus-vivendi` theme and mode line at a larger font size, with
Roost, tmux-control and Magit and nothing else. It used a separate state
directory and tmux socket named `roost-demo`, which appear in the task details
and terminal tab bar; a normal setup shows `~/.local/share/roost` and your
tmux-control socket. The terminals' shell prompt is the author's.

| Image | What it shows |
| --- | --- |
| `roost-dashboard.jpg` | The dashboard alone, with four tasks on two machines: one waiting for permission, two finished (one uncommitted, one committed), one working. The numbered key was added with ImageMagick |
| `roost-new-task.jpg` | A draft opened on an Org heading in `notes.org`: the heading and its notes are the prompt, with the derived name and the Issue field |
| `roost-terminal.jpg` | The `budget-alerts` agent's own terminal on `claylien`, opened with `RET`, asking before it creates a file |
| `roost-menu.jpg` | `h`'s command menu below the dashboard, naming the task its commands act on |
| `roost-workspace.jpg` | The `tags` agent's summary beside the task shell (`t`), where the new `--tag` filter was tried by hand |
| `roost-review.jpg` | Magit on the `skip duplicates` worktree on `claylien` (`r`), with two review notes (`;`) under the agent's change. Retaken on 2026-10-09 in the same configuration, after Claude Code 2.1.289 (Haiku 4.5) made the change, asking before its edits and test runs |
| `roost-task-panel.jpg` | The `search` task's panel (`?`): its reply, a commit ahead of `main`, the prompt, actions and details |

## Try the same workflow

1. In a Git project, press `c` in `roost-status` (or run `M-x roost-new-task`).
   Check the project, write a prompt such as:

   > Importing the same bank export twice duplicates every entry. Skip entries
   > already in the ledger (same date, description and amount) and report how
   > many were skipped. Add tests and run them. Leave the change uncommitted for
   > review.

   and press `C-c C-c`.
2. Answer the agent's trust and permission prompts in its terminal. Start a
   second task the same way; use `n` to move between agents waiting for you.
3. Press `t` for a shell in the task's worktree and run the tests yourself.
4. Press `r` to review and commit in Magit.
5. If another task merged first, press `u` to bring this one up to date (let the
   agent resolve any conflicts), then `m` to merge it and clean up.

The disposable projects, tasks and capture state were removed afterwards.
