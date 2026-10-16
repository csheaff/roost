# The README's screenshots and clip

The images and the clip are native captures of GUI Emacs, taken while Claude
Code worked on two small disposable projects: `notes`, a notes CLI on the Mac,
and `ledger`, an expense-ledger CLI on the SSH host `claylien`. Every agent was
a real Claude Code session (`--model haiku`), in its own terminal with its
normal permission prompts. They ran with `--permission-mode acceptEdits`, so
they asked before commands but not before edits.

The capture Emacs was a plain Emacs 32 configuration, so that nothing personal
distracts: the stock `modus-vivendi` theme and mode line, Menlo at 15 points,
the fringe and margin given the theme's background, and Roost, tmux-control and
Magit and nothing else. It had `roost-sidebar-mode`, `roost-task-panel-mode`
and `roost-animations` on, and `roost-workspace` set to `nil`. It used a
separate state directory and tmux socket named `roost-demo`; a normal setup
shows `~/.local/share/roost` and your tmux-control socket.

| File | What it shows |
| --- | --- |
| `roost-hero.png` | Six agents on two machines: the sidebar, the terminal of `budget-alerts` on `claylien` asking to run `python3 -m unittest`, and that task's panel |
| `roost-dashboard.png` | The dashboard of the same six tasks, with `export` at work |
| The clip | One task from an Org heading in `plans.org` to `main`: the draft, `n` to `budget-alerts` and its answer, a review note in Magit, the agent's revision and commit, and the merge |
| `roost-new-task.png` | Not in the README since the clip: a draft opened on an Org heading, the heading and its notes the prompt |
| `roost-review.png` | Not in the README since the clip: Magit on a task with a review note under the agent's change, and the box for another |

## How they were made

`roost-hero.png`, `roost-dashboard.png` and the clip were taken on
2026-10-16, for the sidebar that marks the task you are on with a band and
names each task's status in a word. Six tasks were started with the prompts
of the previous captures. To have one agent asking and one working at the
moment of each capture, `budget-alerts`, `due-dates` and `export` were given
follow-up prompts in their terminals, such as asking `budget-alerts` to show
amounts with a thousands separator and then run its tests.

The clip was recorded as a movie of the Emacs window alone, with keys
pressed through Emacs's input queue, and edited with ffmpeg:

- The waits are cut, and the agent's two stretches of work play four times
  faster, marked in the title bar.
- The title bar names each key as it is pressed. These captions were added
  in editing, as were the title bar's window buttons, which macOS replaces
  with a recording indicator while a window is recorded.
- The agent's last reply quoted the git author's email address; its three
  lines are blacked out while they are on screen.
- The new task's agent ran with `--permission-mode auto`, so its commands
  were not asked about; `budget-alerts` kept `acceptEdits`, which is why it
  asks.
- Two tries at a note on a line wider than the diff's window, where the note
  box did not open, were cut, and the note was written on a shorter line.

`roost-new-task.png` dates from 2026-10-10 and `roost-review.png` from
2026-10-11, in the same configuration. The disposable projects, tasks and
capture state were removed afterwards each time.

## Try the same workflow

1. In a Git project, press `c` in `roost-status` (or run `M-x roost-new-task`),
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
