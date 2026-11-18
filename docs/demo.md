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
nil. It used a separate state directory and tmux socket named
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
| `roost-show-images.gif` | `vectorise-signals`' terminal alone, then beside the two images its agent shows together: the signals a line of detectors records, and the reconstruction |
| `roost-show-page.gif` | `replay-reconstruction`'s terminal alone, then beside the page its agent wrote, as it plays a filtered back projection one projection at a time |
| `roost-show-as-written.gif` | `explain-back-projection`'s terminal alone, then beside the page Pi draws, as the model writes it |

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

## What an agent shows

The three GIFs under "What an agent can show you" were taken on
2026-11-17, with Roost as it is after 0.12.0, in the same capture Emacs at
150 columns by 42 lines, with the sidebar and panel off and
`roost-agent-pages` on. Two agents were Claude Code 2.1.326 with Sonnet
5.5, in the auto mode it starts in, and the third Pi 1.5.2 with
gpt-6.2-sol, through an OpenAI login. Their projects were disposable
copies of two small public
repositories of the author's:
[filt-back-proj](https://github.com/csheaff/filt-back-proj), a filtered
back projection of the Shepp-Logan phantom, and
[pa-tomography-xu-wang](https://github.com/csheaff/pa-tomography-xu-wang),
Xu and Wang's universal back-projection for photoacoustic tomography. The
agents' Python had numpy, scipy, matplotlib and Pillow.

Each GIF begins with the terminal alone, so that it shows Roost opening
the window: nothing but the request was typed. The two of Claude Code are
of a picture its agent had shown before, closed with `q` and asked for
again.

`vectorise-signals` was asked to make `py/pa_tom_sim.py` run without a
display, which it no longer did, to vectorise `getSignals`, and to show two
pictures together: the signals the detectors along y = 0 record, signed, in
blue and red, and the reconstruction in a hot colour map. It showed one
figure of both. Asked for two images on a black background, kept in the
repository, with zero black in the signals and their colour scale clipped
at a third of the peak, it showed the two in the GIF, and said what each
shows. The GIF is it being asked for them once more, as it happened: the
images came three seconds after the request.

`replay-reconstruction` was asked for a page that shows the reconstruction
building as each projection is added, with a play button and a slider, by
the script's own filter and back projection. Claude Code has a tool of its
own that publishes a page, and began with that; told to show the page
beside its terminal, it used Roost's. It was then asked to play the page
as it opens and again at its end, to keep the rays off the reconstruction,
and to lay it out for the window Roost gives a page, which nobody resized.
The GIF is it being asked for the page once more. The agent took a minute
to send the page again, and the GIF leaves that minute out, where the
count of seconds in the terminal jumps; it ends when the replay has gone
through once.

`explain-back-projection`, the Pi task on the photoacoustic copy, was
asked how `perfTomog` back-projects the signals and which lines do it, and
then to draw that as a page: the detectors in a row, a target above them,
and the arc each detector spreads its signal over, all crossing at the
target. Its first drawing was small, and its second had eleven half
circles, nearly all of them white. The GIF is the third, asked for with
each arc in its detector's colour and the detectors spread across the
width. Pi worked for fourteen seconds before the model began the page,
most of which the GIF leaves out, and the model wrote the page for
thirty-one, which the GIF plays at twice the speed. The page's window
opened as the model began, and each piece showed as it came.

Frames were taken with `screencapture` at about nine a second and made
into GIFs 1,000 pixels wide with ffmpeg, of 64 colours for the replay and
128 for the other two. WebKit paints
nothing while its frame is covered, so the frame was kept above the others
while the page played.

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
