# The README screenshots

The images are native captures of GUI Emacs on 2026-10-10, taken while Claude
Code worked on two small disposable projects: `notes`, a notes CLI on the Mac,
and `ledger`, an expense-ledger CLI on the SSH host `claylien`. Every agent was
a real Claude Code session (`--model haiku`), in its own terminal with its
normal permission prompts. They ran with `--permission-mode acceptEdits`, so
they asked before commands but not before edits.

The capture Emacs was a plain Emacs 32 configuration, so that nothing personal
distracts: the stock `modus-vivendi` theme and mode line, Menlo at 15 points,
the fringe and margin given the theme's background, and Roost, tmux-control and
Magit and nothing else. It had `roost-sidebar-mode`, `roost-task-panel-mode`
and `roost-animations` on, and `roost-workspace` set to `none`. It used a
separate state directory and tmux socket named `roost-demo`; a normal setup
shows `~/.local/share/roost` and your tmux-control socket.

| Image | What it shows |
| --- | --- |
| `roost-hero.png` | Five agents on two machines: the sidebar, the terminal of `budget-alerts` on `claylien` asking to run `python3 -m unittest`, and that task's panel |
| `roost-new-task.png` | A draft opened on an Org heading in `plans.org`: the heading and its notes are the prompt, with the derived name |
| `roost-dashboard.png` | The dashboard a little later, with a sixth task, `export`, just started |
| `roost-review.png` | Magit on the `skip-duplicates` worktree on `claylien` (`r`), with two review notes (`;`) under the agent's change |

## Try the same workflow

1. In a Git project, press `c` in `roost-status` (or run `M-x roost-new-task`).
   Check the project, write a prompt such as:

   > Importing the same bank export twice duplicates every entry. Skip entries
   > already in the ledger (same date, description and amount) and print how
   > many were skipped. Add a test for it, then run the tests.

   and press `C-c C-c`.
2. Answer the agent's trust and permission prompts in its terminal. Start a
   second task the same way; use `n` to move between agents waiting for you.
3. Press `t` for a shell in the task's worktree and run the tests yourself.
4. Press `r` to review in Magit, `;` on a line to write a note for the agent,
   and `@` to send it your notes.
5. If another task merged first, press `u` to bring this one up to date (let the
   agent resolve any conflicts), then `m` to merge it and clean up.

The disposable projects, tasks and capture state were removed afterwards.
