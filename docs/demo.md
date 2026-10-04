# The README screenshots

The images are native captures of GUI Emacs on 2026-10-04, taken while real
agents worked on two small disposable projects: `ledger`, an expense-ledger CLI
on the SSH host `claylien`, and `notes`, a notes CLI on the Mac. Claude Code ran
Haiku 4.5 and Codex ran `gpt-6-luna`, each in its own terminal with its normal
permission prompts.

The capture Emacs used the author's configuration (FiraCode, modus-vivendi,
xah-fly-keys) at a larger font size, without the tab line. It used a separate
state directory and tmux socket named `roost-qa`, which appear in the task
details; a normal setup shows `~/.local/share/roost` and your tmux-control socket.

| Image | What it shows |
| --- | --- |
| `roost-dashboard.jpg` | Four tasks across two hosts: a Codex task that committed its work (`↑1`), Claude tasks ready with uncommitted changes or asking for permission, and the selected task's Claude Code permission prompt below |
| `roost-new-task.jpg` | A draft with a multi-line prompt and its derived name, beside the dashboard |
| `roost-workspace.jpg` | Claude Code's summary beside the task shell, where the tests were rerun independently |
| `roost-review.jpg` | Magit over TRAMP on the remote worktree, expanding the agent's change |
| `roost-task-panel.jpg` | Captured later the same day while Roost was developed with Roost: a Claude Code task on `claylien` that changed Roost's own helper, after answering Copilot's review of its pull request (#2) |

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
