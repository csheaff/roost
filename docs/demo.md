# A small development task

The README screenshots were captured from a real disposable project in GUI
Emacs on 2026-10-03. Claude Code and the supporting shell ran on `claylien` over
SSH. The project was a tiny Python greeting library; it contained no user
project code. Claude used its normal permission prompts.

## Try the same workflow

1. Start in a Git project and run `M-x roost-new-task`. Choose the project,
   name the task `trim-greeting`, leave the starting ref empty to use the primary
   checkout's branch, and provide a prompt such as:

   > Update greet(name) to trim surrounding whitespace and use world when the
   > name is empty or whitespace-only. Add regression tests and run them. Do not
   > commit; leave the diff for my review.

2. Answer Claude's startup and edit permissions in its terminal.
3. Run `M-x roost-shell`. The supporting shell opens in the task's worktree.
   Independently run the project's tests; this example uses
   `python3 -B -m unittest -v`.
4. Run `M-x roost-review`, expand the file changes in Magit, and review them.
   Stage and commit using your normal Magit commands.
5. Run `M-x roost-task-info` to check the project and integration branch. After
   reviewing and committing, use its merge/retire action or
   `M-x roost-merge-retire`.

The screenshots show the working and review stages. Retiring the task merges
its committed work into the recorded integration branch and removes its clean
worktree, topic branch, and task window. Both checkouts must be clean.

## Capture notes

- The images are native Emacs window captures, not generated mockups.
- The terminal response, passing tests and Magit diff come from the same actual
  Claude task.
- A separate temporary Emacs frame was used for legible screenshots. The user's
  original workspace and existing agent session were retained.
- Theme, font, window arrangement and keybindings are user configuration.
  The command names above work without the author's `SPC r` bindings.
- The workspace capture uses a vertical tmux layout; review and task details
  use a single Emacs window for readability. All seven tests passed in both
  Claude's run and the independently used supporting shell.
- The demo task and its disposable repository were removed after capture.

The older Pi-based screenshots were removed because they describe an obsolete
workflow. For broader lifecycle testing, see [validation](validation.md).
