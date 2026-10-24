# The README's screenshots

The images are native captures of GUI Emacs, taken while Claude Code worked
on two small disposable projects: `notes`, a notes CLI on the Mac, and
`ledger`, an expense-ledger CLI on the SSH host `claylien`. Every agent was a
real Claude Code session (`--model haiku`), in its own terminal with its
normal permission prompts. They ran with `--permission-mode acceptEdits`, so
they asked before commands but not before edits.

The capture Emacs was a plain Emacs 32 configuration, so that nothing personal
distracts: the stock `modus-vivendi` theme and mode line, Menlo at 15 points,
and Roost, tmux-control and Magit and nothing else. It had
`roost-sidebar-mode` and `roost-task-panel-mode` on, `roost-animations` off,
as it is by default, and `roost-workspace` set to `nil`. It used a separate
state directory and tmux socket named `roost-demo`; a normal setup shows
`~/.local/share/roost` and your tmux-control socket.

| File | What it shows |
| --- | --- |
| `roost-hero.png` | Six agents on two machines: the sidebar, the terminal of `budget-alerts` on `claylien` asking to run `python3 -m unittest`, and that task's panel |
| `roost-new-task.png` | `plans.org` beside the draft that `C-c r c` made from its heading, which started `export` |
| `roost-review.png` | `tag-filter`'s terminal above the diff of `notes.py`, opened from its panel, with a review note under a line |
| `roost-dashboard.png` | The dashboard of the same six tasks, with `budget-alerts` asking and `export` at work |

## How they were made

All four were taken on 2026-10-24, with Roost as of 0.11.0 and the changes
after it, once its views kept colour for what needs you and the panel beside
a terminal had grown shorter. They replace the stills of 2026-10-21, which
replaced a clip that played a task through. Five tasks were started with
prompts that ask the agent to run the tests with `python3 -m unittest`, and
their prompts answered in their terminals until each finished. `export` was
then drafted from the heading in `plans.org`. To have one agent asking and
one working at the moment of the hero and the dashboard, `budget-alerts` was
asked to show amounts with a thousands separator and run its tests, and
`export` was given a further prompt just before each capture. The review
note was written in the note box and saved; the box itself floats over the
diff in a frame of its own, which a capture of the Emacs window leaves out.

Each was taken at its own frame size, so that the text reads at the width
GitHub shows the README: 172 columns by 36 lines for the hero, 132 by 19 for
the draft, with the sidebar and panel off, 156 by 34 for the review, with the
sidebar off, and 132 by 15 for the dashboard, with both off. The capture
Emacs was given focus for a moment before each capture, so that its window
looks active. The disposable projects, tasks and capture state were removed
afterwards.

## Try the same workflow

1. In a Git project, press `c` in `roost-dashboard` (or run `M-x roost-new-task`),
   or `C-c r c` on an Org heading. Check the project, write a prompt such as:

   > Importing the same bank export twice duplicates every entry. Skip entries
   > already in the ledger (same date, description and amount) and print how
   > many were skipped. Add a test for it, then run the tests.

   and press `C-c C-c`.
2. Answer the agent's trust and permission prompts in its terminal. Start a
   second task the same way; use `n` to move between agents waiting for you.
3. Press `t` for a shell in the task's worktree and run the tests yourself.
4. Click a file in the task's panel, or press `r` to review in Magit; `;` on a
   line writes a note for the agent, and `@` sends it your notes.
5. If another task merged first, press `u` to bring this one up to date (let the
   agent resolve any conflicts), then `m` to merge it and clean up.
