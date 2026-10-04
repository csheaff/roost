# Roost

Claude Code tasks in Emacs, locally or over SSH. Claude keeps its own terminal
interface. Roost joins Git worktrees, persistent tmux windows,
[tmux-control](https://github.com/csheaff/tmux-control), TRAMP, Magit, and
[perspective.el](https://github.com/nex3/perspective-el) into one task workflow.

## The workflow

1. Run `M-x roost-new-task` from a project or choose its directory. A TRAMP path
   such as `/rpc:claylien:/home/clay/code/project/` creates the task on that host.
2. Give it a name, starting Git ref (default `HEAD`), and optional initial prompt.
   Roost creates a topic branch, worktree, and tmux window, then opens the actual
   Claude Code terminal. Answer startup and permission prompts there as usual.
3. Open `roost-status` to see tasks across hosts. `RET` restores a task's terminal
   and perspective; arrange code and review buffers alongside it as you prefer.
   `roost-next-waiting` cycles through sessions ready for input or permission.
4. Use `roost-review` for Magit in the worktree, or `roost-diff` for tracked changes
   against the starting commit. Remote files use your configured TRAMP method.
   `project.el` and Projectile can use the worktree's normal project directory.
5. Review and commit in Magit, then `roost-merge-retire` to merge into the recorded
   integration branch in the primary checkout and remove the task's resources.
   Or merge manually and run `roost-retire`.

Closing Emacs or losing SSH leaves Claude running in tmux. Reopen Roost and
select the task to reconnect. `roost-stop` stops its window and processes while
keeping the worktree, branch, and conversation. `roost-resume` starts a new
window with Claude's recorded conversation ID. If Claude never reached
`SessionStart`, resume starts a new conversation instead.

## Install

Requirements: Emacs 29.1+, tmux-control, and, on each task host, Python 3.9+, Git,
tmux, and an installed, authenticated Claude Code CLI. Python uses only its
standard library. Remote hosts need key/agent-based SSH authentication; use SSH
config aliases for ports, ProxyJump, or other connection settings.

Keep `scripts/roost_remote.py` beside `roost.el`; Roost installs a versioned copy
on each host automatically. Existing tasks keep their original helper until
resumed, so upgrading Roost does not change a running Claude process.

```elisp
(use-package roost
  :ensure nil
  :load-path "~/code/roost"
  :commands (roost-status roost-new-task roost-switch-task)
  :custom
  (roost-hosts '("claylien" nil))) ; nil = local
```

For Straight, include the helper directory in the package recipe:

```elisp
:straight (roost :type git :host github :repo "csheaff/roost"
                 :files ("roost.el" "scripts"))
```

Magit is optional (`roost-review` falls back to Dired). If perspective.el is
active, each task gets a separate saved window arrangement. Without it, task
switching still opens the correct terminal. Other perspective packages do not
provide the same API; they are not integrated.

## Commands

| Dashboard key | Command | Action |
| --- | --- | --- |
| `RET` | `roost-open-task` | Open selected task |
| `c` / `d` | `roost-new-task` | Create a worktree and Claude window |
| | `roost-switch-task` | Choose a task across hosts |
| `n` | `roost-next-waiting` | Cycle through ready/permission sessions |
| `r` | `roost-review` | Magit status in the task's worktree |
| `D` | `roost-diff` | Tracked changes since task creation |
| `e` | `roost-send` | Paste a prompt literally, then Enter |
| | `roost-send-region` | Send selected text with file/line context |
| `s` | `roost-resume` | Restart a stopped/exited task |
| `k` | `roost-stop` | Stop the window; retain all work |
| `x` | `roost-retire` | Remove a clean task already merged into its integration branch |
| `m` | `roost-merge-retire` | Merge committed work, then retire |
| `g` | `roost-refresh` | Refresh status and Git statistics |
| | `roost-watch-mode` | Toggle periodic background status refresh |

The dashboard's `Since` column measures time since the last status event.
`Changes` is Git's tracked diffstat against the recorded starting commit; inspect
Magit to see untracked files as well. Background polls skip Git; press `g` for
fresh statistics. An offline host retains its last known tasks and reports
`offline`, rather than declaring Claude crashed.

## Configuration

- `roost-hosts`: hosts monitored by the dashboard. Hosts used to create tasks are
  also remembered locally in `roost-hosts-file` across Emacs restarts.
- `roost-state-directory`: `~/.local/share/roost` on each host, containing private
  task records, per-task hook settings, versioned helpers, and worktrees.
- `roost-socket-name`: defaults to tmux-control's socket, normally `main`.
  Remote operations also use `tmux-control-remote-tmux-socket-setup` and
  `tmux-control-ssh-options`, so the terminal and task manager see the same server.
- `roost-session-name`: nil creates one tmux session per repository, with a general
  shell window and one window per task. Set a name to use an existing session
  instead; a missing session is created. Renaming sessions or renumbering windows
  does not change task identity.
- `roost-claude-command`: executable plus extra arguments, e.g.
  `'("claude" "--model" "sonnet")`. Common CLI installation directories are added
  to the runner's PATH. Roost owns worktree, resume, and hook flags; conflicting
  CLI options are rejected. Claude's normal settings and approval mode still apply.
- `roost-setup-command`: optional shell command run once in a new worktree before
  Claude. It can be directory-local, e.g. `npm ci`; it does not rerun on resume.
- `roost-use-perspectives`, `roost-notify`, `roost-watch-interval` (3 seconds), and
  `roost-request-timeout` (60 seconds) customize the Emacs integration.

For a project setup command:

```elisp
;; .dir-locals.el
((nil . ((roost-setup-command . "npm ci"))))
```

When creating from an existing task worktree, `HEAD` means that task's current
commit. The new task still belongs to the original repository and integrates
into its primary checkout.

Setup is an ordinary project shell command. Review it when Emacs asks about
local variables, and keep Gitignored dependencies out of commits.

## Lifecycle and review

Roost adds observational [Claude hooks](https://code.claude.com/docs/en/hooks)
through a per-task `--settings` file. It does not modify global Claude settings
or approve tool calls. Permission prompts must be answered in the terminal;
`roost-send` refuses to paste into startup and permission prompts.

`running` means Claude submitted a prompt or is using tools. `ready` means it
started or finished a response; it does **not** mean the task is reviewed or
complete. `permission` needs a terminal answer. A Stop event with background
work reports `background`. `failed`, `exited`, and `crashed` distinguish CLI
failure, normal exit, and a missing/dead tmux pane. Disabling hooks externally
can make the finer status information stale.

Task identity is `(SSH host, task ID)`. Window/pane IDs and a pane ownership tag
prevent window renumbering or a restarted server from steering unrelated panes.
Old hooks cannot overwrite a newer resumed run. SSH requests and polling are
asynchronous; rendering the dashboard reads a local cache.

Retirement requires both checkouts to be clean, including untracked files, and
the primary checkout to remain on its recorded integration branch. Roost never
stages, commits, or force-removes work. Unmerged commits block retirement.
Merge conflicts abort the merge that Roost started and retain the task. A
persisted cleanup checkpoint permits retry after interrupted retirement.
The general shell/session remains available after the last task is retired.

## Migration from 0.2

0.3 owns Claude task creation and its registry. It no longer reads
`.pi/side-agents/registry.json` or dispatches `/agent` to a Pi orchestrator.
Existing Pi tasks are untouched and are not imported. The old registry,
agent-session, and status-glyph customization variables no longer apply.
`roost-list` aliases `roost-switch-task`; `roost-kill` aliases `roost-stop`;
`roost-dispatch` aliases `roost-new-task` with its new arguments and prompts.

## Validation

Run `make test compile`. Tests use isolated tmux sockets and temporary Git
repositories; the Claude fixture exercises real hook commands without API
calls. See [validation notes](docs/validation.md) for the checked remote and
native Emacs workflow. This remains experimental software.

## License

GPL-3.0-or-later.
