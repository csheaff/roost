# The README's screenshots

The images are captures of GUI Emacs, taken while agents worked on two small
disposable projects: `ledger`, an expense-ledger CLI on this machine, and
`notes`, a notes CLI on the host `dev`. Every agent was a real session in its
own terminal: eight of Pi 1.5.2, with a model run locally (qwen3.6-35b in LM
Studio), and one of Claude Code 2.1.325 (`--model haiku`, with
`--permission-mode acceptEdits`, so it asked before commands but not before
edits).

The capture Emacs was a plain Emacs 32.0.50 configuration on macOS, so that
nothing personal distracts: the stock `modus-vivendi` theme and mode line,
Menlo, and Roost, Ghostel 0.65.0, ghostel-tmux 0.3.0, Magit and nothing
else. It had `roost-sidebar-mode` and `roost-task-panel-mode` on,
`roost-animations` off, as it is by default, and `roost-workspace` set to
`none`. It used a separate state directory and tmux socket named
`roost-demo`; a normal setup shows `~/.local/share/roost`.

`dev` was a Linux machine reached over SSH, with its own helper, tmux server
and task records. Its Pi sessions used the model on this machine, through a
port forwarded over SSH. Pi was started as `env PI_OFFLINE=1 pi`, which
leaves out its notices of updates; Roost has it send the images it reads.
The title bar was cropped from each capture.

| File | What it shows |
| --- | --- |
| `roost-hero.png` | Nine agents on two hosts: the sidebar, the terminal of `spending-chart`, where Pi has read the chart it drew and the picture shows above its reply, and that task's panel |
| `roost-new-task.png` | `plans.org` beside the draft that `C-c r c` made from its heading |
| `roost-review.png` | `spending-chart`'s terminal above the diff of `ledger.py`, with a review note under a line |
| `roost-dashboard.png` | The dashboard of the same nine tasks, with `budget-alerts` asking |

## How they were made

All four were taken on 2026-11-16, with Roost as it is after 0.12.0 and
terminals through ghostel-tmux; the hero, the review and the dashboard
again that day, once a task's terminal was named by its host and task. `ledger` has a `plot.py` that draws a bar
chart as a PNG with no plotting library. `spending-chart` was asked to add a
`chart` command that draws spending by category with it, to run it, and to
look at the picture with Pi's read tool, which is what puts the picture in
its terminal; it was then asked to read the picture again and say in a
sentence which category is smallest, with Pi's thinking folded (`C-t` in
Pi). The picture is drawn when Pi reads it, and goes blank when Pi draws
its screen again, as after the frame changes size, so each capture was
taken at its size before the last read. The
other Pi tasks were given small features with tests, and left when they
finished. `budget-alerts`, the Claude Code task, was answered until it asked
to run `python3 -m unittest`, and left asking. To have one agent working at
the moment of the hero, `priorities` was started on `dev` just before it.
The review note was saved on its line of the diff of `ledger.py`, which was
opened with `roost-diff` from `spending-chart`.

Each was taken at its own frame size, so that the text reads at the width
GitHub shows the README: 172 columns by 38 lines for the hero, 132 by 20 for
the draft and 132 by 18 for the dashboard, with the sidebar and panel off,
and 156 by 36 for the review, with the sidebar off. The disposable projects,
tasks and capture state were removed afterwards.

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
