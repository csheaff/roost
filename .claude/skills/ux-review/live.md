# Real agents in a scratch Emacs

For what `make qa`'s fake agent can't show: real replies and prompts, Claude
Code's startup questions, timing over SSH. Everything here has its own
server name, state directory and tmux socket, so Clay's Emacs, tasks and
tmux are untouched. Claude Code runs on Haiku in manual permission mode, so
it asks before commands, as a cautious user would have it.

## Set up

Pick a scratch directory `L` and export a current tmux-control there:
`git -C ~/code/tmux-control archive origin/main | tar -x -C $L/tmux-control`
(don't pull Clay's checkout). Make a scratch repository at `$L/ledger`, and
for remote journeys one on claylien under `/tmp`. Then `$L/init.el`, with
`L` and `ROOST` replaced by the scratch directory and the checkout:

```elisp
;;; -*- lexical-binding: t -*-
(setq server-name "roost-live" inhibit-startup-screen t)
(require 'package)
(setq package-user-dir (expand-file-name "elpa-none" "L")
      package-directory-list (list (expand-file-name "~/.emacs.default/elpa-32")))
(package-initialize)
(add-to-list 'load-path "L/tmux-control")
(add-to-list 'load-path "ROOST")        ; the checkout under review
(setq roost-state-directory "~/.local/share/roost-live"
      roost-socket-name "roost-live"
      roost-hosts '(nil "claylien")
      roost-hosts-file "L/hosts.json" roost-projects-file "L/projects.json"
      roost-notes-file "L/notes.json" roost-notify nil
      roost-agent-commands
      '(("claude" "claude" "--model" "haiku" "--permission-mode" "manual")))
(require 'roost)
(roost-watch-mode 1) (roost-sidebar-mode 1) (roost-task-panel-mode 1)
(set-frame-size nil 200 50)
(server-start)
```

Start it in the background with
`/Applications/Emacs.app/Contents/MacOS/Emacs --no-site-file --init-directory $L`.
For the *New to Roost* persona, leave out the three modes and the sidebar,
and add Vertico; for *Evil*, evil-collection from a package directory of
your own.

## Drive it

- `emacsclient --socket-name roost-live --eval '…'` for anything that
  doesn't ask. **Never** run a command that reads the minibuffer this way,
  as `roost-send` without its text: the server waits on it and stops
  answering, and the only way out is to kill that Emacs. Use the pieces the
  commands use: `roost--create-task` for a task, `roost--send-draft` and
  then `roost-send-submit` in its buffer for `@`, `roost-review`,
  `roost-diff`, `roost-task-info`.
- Answer the agent in its terminal as a person would, with tmux: here,
  `tmux -L roost-live send-keys -t PANE Enter`; on claylien, the same over
  `ssh` after `export TMUX_TMPDIR=$HOME/.tmux-sock`. A new folder asks to be
  trusted first (Down, Enter), which writes the folder into
  `~/.claude.json` on that host.
- Read what Roost says: `roost--display-status`, `roost--attention-status`,
  `roost--next-step`, `roost--next-message`, a panel's text through
  `roost--task-info-buffer`, a sidebar row through `roost--sidebar-row`.
- Screenshots: build `test/qa/winid.swift` with `swiftc`, run it with the
  scratch Emacs's PID for its window id, and `screencapture -x -o -l ID`.
  Never capture without a PID, or it shoots Clay's Emacs.

## Clean up

Kill the scratch Emacs (`(kill-emacs)` through its server, else its PID),
`tmux -L roost-live kill-server` here and on claylien, and remove
`~/.local/share/roost-live` on both and the scratch repositories. Say in
the review that the trust prompts added entries to `~/.claude.json`.
