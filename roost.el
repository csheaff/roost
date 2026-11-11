;;; roost.el --- Run coding agents in Git worktrees and tmux -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Clay Sheaff

;; Author: Clay Sheaff
;; Version: 0.11.0
;; Package-Requires: ((emacs "29.1") (tmux-control "0.8.2") (transient "0.4.1"))
;; Keywords: tools, processes
;; URL: https://github.com/csheaff/roost
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Coding agents run in tmux on the task's host.  Roost owns task lifecycle
;; and observational status events; tmux-control owns rendering.  JSON RPC
;; over SSH is asynchronous.  Files and Magit use TRAMP.  Stopping an agent
;; keeps its work.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'json)
(require 'subr-x)
(require 'seq)
(require 'easymenu)
(require 'lisp-mnt)
(require 'tramp)
(require 'parse-time)
(require 'iso8601)
(require 'button)
(require 'transient)
(require 'hl-line)

(declare-function tmux-control-connect-or-switch "tmux-control" (host socket-name session))
(declare-function tmux-control-send-command "tmux-control" (command))
(declare-function tmux-control-query "tmux-control" (command callback))
(declare-function tmux-control-select-pane "tmux-control" (&optional pane))
(declare-function tmux-control-tile "tmux-control" ())
(declare-function tmux-control-tiled-p "tmux-control" ())
(declare-function tmux-control-buffer-host "tmux-control" ())
(declare-function tmux-control-buffer-socket-name "tmux-control" ())
(declare-function tmux-control-buffer-session "tmux-control" ())
(declare-function tmux-control-disconnect "tmux-control" ())
(declare-function tmux-control-reconnect "tmux-control" ())
(declare-function tmux-control-active-pane "tmux-control" ())
(declare-function tmux-control-window-id "tmux-control" ())
(declare-function magit-status "magit-status" (&optional directory cache))
(declare-function magit-diff-working-tree "magit-diff" (&optional rev args files))
(declare-function magit-diff-setup-buffer "magit-diff" (range typearg args files &optional type locked))
(declare-function magit-diff-dwim "magit-diff" (&optional args files))
(declare-function magit-diff-arguments "magit-diff" (&optional mode))
(declare-function magit-diff-type "magit-diff" (&optional section))
(declare-function magit-file-at-point "magit-git" (&optional expand assert))
(declare-function magit-toplevel "magit-git" (&optional directory))
(declare-function magit-current-section "magit-section" ())
(declare-function eieio-oref "eieio-core" (obj slot))
(declare-function magit-section-match "magit-section" (condition &optional section))
(declare-function magit-section-show "magit-section" (section))
(declare-function magit-map-sections "magit-section" (function &optional section))
(declare-function magit-insert-heading "magit-section" (&rest args))
(declare-function magit-add-section-hook "magit-section" (hook function &optional at append local))
(declare-function magit--insert-log "magit-log" (keep-error revs &optional args files))
(declare-function magit-insert-log "magit-log" (revs &optional args files))
(declare-function magit-log-insert-child-count "magit-log" ())
(declare-function magit-rev-verify "magit-git" (rev))
(declare-function magit-diff-range "magit-diff" (rev-or-range &optional args files))
(declare-function eieio-oset "eieio-core" (obj slot value))
(declare-function magit-get-upstream-branch "magit-git" (&optional branch))
(declare-function persp-switch "perspective" (name))
(declare-function persp-kill "perspective" (name))
(declare-function persp-forget-buffer "perspective" (buffer))
(declare-function persp-scratch-buffer "perspective" (&optional name))
(declare-function persp-add-buffer "perspective" (buffer-or-name))
(declare-function persp-is-current-buffer "perspective" (buf &optional include-global))
(declare-function persp-current-name "perspective" ())
(declare-function persp-names "perspective" ())
(declare-function persp-format-name "perspective" (name))
(declare-function persp-rename "perspective" (name))
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function flymake-diagnostic-end "flymake" (diag))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function svg-create "svg" (width height &rest args))
(declare-function svg-rectangle "svg" (svg x y width height &rest args))
(declare-function svg-line "svg" (svg x1 y1 x2 y2 &rest args))
(declare-function svg-image "svg" (svg &rest props))
(declare-function svg-circle "svg" (svg x y radius &rest args))
(declare-function svg-polygon "svg" (svg points &rest args))
(declare-function svg-polyline "svg" (svg points &rest args))
(declare-function dired-get-marked-files "dired" (&optional localp arg filter distinguish-one-marked error))
(declare-function ediff-files "ediff" (file-a file-b &optional startup-hooks))
(declare-function evil-define-minor-mode-key "evil-core" (state mode key def &rest bindings))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-before-first-heading-p "org" ())
(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-entry-end-position "org" ())
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-entry-put "org" (epom property value))

(defvar tmux-control-default-socket-name)
(defvar magit-root-section)
(defvar magit-diff-buffer-file-locked)
(defvar magit-buffer-diff-files)
(defvar magit-buffer-diff-range)
(defvar magit-buffer-range)
(defvar magit-root-section)
(defvar magit-status-headers-hook)
(defvar magit-status-sections-hook)
(defvar magit-refresh-buffer-hook)
(defvar magit-buffer-log-args)
(defvar magit-insert-section--current)
(defvar tmux-control-remote-tmux-socket-setup)
(defvar tmux-control-ssh-options)
(defvar tmux-control-session-activity)
(defvar server-process)
(defvar server-socket-dir)
(defvar server-name)
(defvar persp-mode)
(defvar persp-modestring-short)
(defvar persp-modestring-dividers)

;;;; Customization

(defgroup roost nil
  "Coding agent tasks in persistent local or remote tmux."
  :group 'tools)

(defcustom roost-hosts '(nil)
  "SSH hosts to monitor.  Nil means local.  Task hosts are also remembered."
  :type '(repeat (choice (const :tag "Local" nil) string)))

(defcustom roost-state-directory "~/.local/share/roost"
  "Host-side directory for task records, helper, settings, and worktrees."
  :type 'string)

(defcustom roost-default-agent "claude"
  "Default agent offered when creating a task.
Existing tasks retain their agent."
  :type '(choice (const "claude") (const "codex") (const "pi") (const "opencode")))

(defcustom roost-agent-commands '(("claude" "claude") ("codex" "codex") ("pi" "pi")
                                  ("opencode" "opencode"))
  "Executable and extra arguments for each agent, evaluated on the task host.
Such as (\"claude\" \"claude\" \"--model\" \"sonnet\") for Claude Code.
Roost owns worktree, resume and hook flags, and refuses ones that clash."
  :type '(alist :key-type string :value-type (repeat string)))

(defconst roost--agents '("claude" "codex" "pi" "opencode"))

(defun roost--agent-name (agent)
  "AGENT's name as its makers write it."
  (pcase agent ("pi" "Pi") ("opencode" "OpenCode") (_ (capitalize agent))))

(defcustom roost-setup-command nil
  "Optional project setup shell command, run before the agent in new worktrees.
May be set directory-locally.  Not rerun on resume.  It runs in the
worktree, once its submodules are checked out and the ignored files the
project's .worktreeinclude lists are copied there, with the project's
primary checkout in $ROOST_REPO."
  :type '(choice (const nil) string))

(defcustom roost-teardown-command nil
  "Optional shell command run in a task's worktree just before Roost removes it.
Merging, retiring and discarding a task run it, as for cleaning up what
a tool keeps for the worktree elsewhere.  May be set directory-locally;
it runs on the task's host, with the primary checkout in $ROOST_REPO.
After two minutes it is stopped.  If it fails, Roost warns, and removes
the worktree anyway."
  :type '(choice (const nil) string))

(defconst roost--teardown-seconds 120
  "Seconds a host lets a teardown command run, as TEARDOWN_SECONDS says.
Emacs waits this much longer for a request that runs one.")

(defconst roost--create-seconds 600
  "Seconds longer than `roost-request-timeout' Emacs waits for a task to be made.
Checking out a worktree takes that long in a large repository, such as
one whose Git LFS files run to gigabytes.")

(defcustom roost-branch-prefix "roost/"
  "Prefix for task topic branches, which are named PREFIX<task>-<id>.
Existing tasks keep their branch."
  :type 'string)

(defcustom roost-socket-name nil
  "Tmux socket, or nil to use tmux-control's configured default."
  :type '(choice (const nil) string))

(defvar roost-startup-grace 15
  "Seconds after which a task still starting is taken to be waiting at a prompt.
Agents report nothing until their folder-trust or hook-review prompts
are answered, so a long start usually needs you.")

(defcustom roost-watch-interval 3
  "Seconds between asynchronous status refreshes."
  :type 'number)

(defvar roost-watch-unfocused-interval 15
  "Seconds between status refreshes while no Emacs frame has focus.
Notifications can then come that much later; nothing waits on screen.")

(defvar roost-request-timeout 60
  "Maximum seconds for a host operation.")

(defcustom roost-ssh-share-connections t
  "Whether Roost's requests to a host share one SSH connection.
Each request is a separate ssh command, so sharing saves a handshake per
poll.  The shared connection's socket lives in `roost-state-directory'
on this machine and closes a minute after the last request.  Set to nil
to leave connection sharing to your ssh configuration."
  :type 'boolean)

(defcustom roost-org-link-tasks t
  "Whether a task started from an Org entry is recorded on that entry.
The entry gets a ROOST_TASK property holding the task's id, and Roost
commands run on the entry, or on its agenda line, act on that task."
  :type 'boolean)

(defcustom roost-jira-query
  "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
  "JQL for the Jira work items a draft can start from, or nil for none.
With twg, Atlassian's Teamwork Graph CLI, installed and signed in on
this machine, `roost-compose-set-issue' lists them beside the project's
GitHub issues.  The default is your open work.  May be set
directory-locally, as to a project's own backlog:
project = PROJ AND statusCategory != Done ORDER BY rank."
  :type '(choice (const :tag "No Jira work items" nil) string)
  :safe #'string-or-null-p)

(defcustom roost-sidebar-width 30
  "Width in columns of the task sidebar; see `roost-sidebar-mode'."
  :type 'natnum)

(defcustom roost-sidebar-recent-projects 3
  "How many projects with no tasks the sidebar lists on each host.
They are the ones you used last, below the tasks, and a click on one
starts a task there.  0 lists none."
  :type 'natnum)

(defcustom roost-task-panel-width 44
  "Width in columns of the task panel beside a task's terminal.
See `roost-task-panel-mode'."
  :type 'natnum)

(defcustom roost-workspace 'auto
  "How each task keeps its own window arrangement.
`perspective' uses perspective.el, `tab-bar' a tab per task, and nil
leaves your windows alone.  `auto' uses perspective.el when
`persp-mode' is on, otherwise tab-bar when `tab-bar-mode' is on."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "perspective.el" perspective)
                 (const :tag "A tab per task" tab-bar)
                 (const :tag "None" nil)))

(defcustom roost-evil-state 'emacs
  "Evil state for the dashboard and task panels, or nil for Evil's default.
In Emacs state Roost's single keys work, and \`j' and \`k' move between tasks."
  :type '(choice (const emacs) (const motion) (const normal) (const :tag "Evil's default" nil)))

(defcustom roost-compact-mode-line t
  "Collapse Roost perspectives into one clickable group in the mode line.
The group shows the current task and the number of other task workspaces.
Ordinary perspectives retain their existing labels and click actions."
  :type 'boolean)

(defcustom roost-notify t
  "Notify on transitions requiring attention."
  :type 'boolean)

(defcustom roost-notify-function nil
  "Optional function of TITLE and BODY to display notifications."
  :type '(choice (const nil) function))

(defcustom roost-task-status-functions nil
  "Functions called with TASK, PREVIOUS and STATUS when a task's status changes.
PREVIOUS and STATUS are the status its host recorded before and now:
\"starting\", \"running\", \"ready\" (its turn is over), \"permission\",
\"failed\", \"crashed\", \"exited\" or \"stopped\", and, as Roost lets it
go, \"retired\", \"discarded\" or \"forgotten\".  They are called for
changes this Emacs sees, whether you or its agent made them, not when
Roost first sees a task.  TASK is an alist: `alist-get' reads its `name',
`id', `host' (nil on this machine), `agent', `branch', `worktree' and
`integrationBranch'.  A function that fails is reported, and the rest
still run."
  :type 'hook)

(defcustom roost-task-merged-functions nil
  "Functions called with TASK and BRANCH once TASK's work is merged into BRANCH.
That is when `m' merges it, or when Roost sees GitHub merge its pull
request while Emacs runs, into the branch the pull request went to.
Each merge is reported once, though both can see it.  Roost asks GitHub
every two minutes, and sees only the merges of the branch's latest
commit: one followed by new commits before it asks goes unreported.
TASK is an alist, as for `roost-task-status-functions'.  A function that
fails is reported, and the rest still run."
  :type 'hook)

(defcustom roost-hosts-file (locate-user-emacs-file "roost/hosts.json")
  "Local file remembering hosts used by Roost."
  :type 'file)

(defcustom roost-projects-file (locate-user-emacs-file "roost/projects.json")
  "Local file remembering project checkouts used for tasks."
  :type 'file)

(defcustom roost-magit-status-sections t
  "Whether Magit's status of a task's worktree names the task.
It then also shows the agent's latest reply, folded, and the task's
commits not yet merged into its integration branch.  Review notes and
Roost's keys in Magit do not depend on this."
  :type 'boolean)

(defcustom roost-merge-style 'squash
  "How `roost-merge-retire' brings a task's work into its integration branch.
`squash' adds one commit holding all the task's work, with a message
made from its commits, so each task is one change in the history and
the merges that brought the task up to date (`roost-update') leave no
trace there.  `merge' makes a merge commit, keeping the task's commits
as they are."
  :type '(choice (const :tag "Merge commit" merge)
                 (const :tag "One squashed commit" squash)))

(defcustom roost-large-change '(:lines 400 :files 10 :directories 3)
  "How large a task's changes get before its row is marked ±.
A task is marked once its changes reach any of these: `:lines', lines
added and removed together; `:files', files changed; `:directories',
top-level directories that hold changed files.  They count from where
the task's work leaves its integration branch, uncommitted work and
new files included.  Leave one out to mark by the others, or set this
to nil to mark none.  Reviews of larger and more spread-out changes
find less and take longer; the numbers are rough."
  :type '(choice (const :tag "Mark none" nil)
                 (plist :tag "Mark at" :options ((:lines natnum) (:files natnum) (:directories natnum)))))

(defcustom roost-program-status nil
  "Whether Roost reads the status an agent reports to its terminal.
Claude Code 2.1.295, Codex 0.163.0 and Pi 1.1.0 and later report
whether they work or wait on you, by the Program Status Protocol (OSC
7501), which tmux drops; Claude Code and Pi report only to a terminal
that answers their probe, which tmux does not.  With this on, a task's
agent gets a terminal of its own, relayed to its tmux pane, that
answers.  Its status then shows at once when you approve a request, and
for Claude Code when you press Esc or decline one, which hooks don't
report.  New tasks, and tasks you resume, follow this."
  :type 'boolean)

(defcustom roost-agent-offers t
  "Whether a task's agent can offer tasks of their own, for you to start.
An agent that comes across work outside its task, such as a bug in
code it read, offers it, and goes on with its own work.  The offer
waits, dim, under its task in the dashboard and sidebar, until you open
it as a new task draft, have that agent do it there, or dismiss it.
An agent in a conversation, which has no project, offers tasks in your
projects: ask it to plan a piece of work, and each task it would split
it into waits under the conversation for you to start.
Roost gives the agent tools for this, from an MCP server of its own,
with a few sentences on when to use them, which cost tokens on each of
its requests.  Only Claude Code takes them so far.  Tasks you start
after changing this follow it; nil gives agents no tools of Roost's."
  :type 'boolean)

(defcustom roost-remote-control nil
  "Whether each Claude Code task starts with Remote Control, named for the task.
The task then shows in the Claude app and at claude.ai/code, by its
name, where you can read it and answer it, and which notify your phone
when its agent needs a decision.  Its name also shows in Claude's own
list of sessions.  Roost starts Claude with `--remote-control' and
`--name' for this; Remote Control needs a Claude subscription, and
Claude says so in the task's terminal without one.  Other agents have
no such app, and start as ever.  Tasks you start after changing this
follow it."
  :type 'boolean)

(defcustom roost-decorate t
  "Whether Roost's views are drawn with more than their text.
A quiet tint behind a status that wants you, a band behind what is
wrong with a task, a hairline under each view's heading, changed lines
in a column, and a little air between lines.  Each colour is made from
your theme's own, afresh when the theme changes, and no text differs:
nil draws the same words with none of it, as a terminal with few
colours does anyway."
  :type 'boolean)

(defcustom roost-notes-file (locate-user-emacs-file "roost/notes.json")
  "Local file keeping review notes not yet sent to an agent.
See `roost-note'."
  :type 'file)

;;;; Faces

(defface roost-title '((t :inherit bold :height 1.1))
  "Titles of Roost buffers.")
(defface roost-heading '((t :inherit bold))
  "Group and section headings.")
(defface roost-label '((t :inherit shadow))
  "Face for the word that names a block of the task panel.
Quiet: what the block holds is what you read.")

;;;; Colours made from the theme's

(defvar roost--mixed (make-hash-table :test 'equal)
  "Colours `roost--mix' made, by what they were made from.")

(defun roost--mix (colour onto amount)
  "COLOUR laid over ONTO, AMOUNT of it from 0 to 1, as a colour's name.
Nil where either can't be read as a colour, as on a terminal that
leaves its own unsaid."
  (let ((key (list colour onto amount)))
    (or (gethash key roost--mixed)
        (when-let* (((stringp colour))
                    ((stringp onto))
                    (over (ignore-errors (color-name-to-rgb colour)))
                    (under (ignore-errors (color-name-to-rgb onto))))
          (puthash key
                   (apply #'color-rgb-to-hex
                          (append (cl-mapcar (lambda (a b) (+ (* amount a) (* (- 1 amount) b))) over under)
                                  '(2)))
                   roost--mixed)))))

(defun roost--decorated-p ()
  "Whether this display can show what `roost-decorate' draws."
  (and roost-decorate (display-color-p) (> (display-color-cells) 255)))

(defun roost--tint (face &optional amount)
  "A background that says FACE's colour quietly: AMOUNT of it on the frame's own.
An eighth unless given.  Nil where `roost-decorate' is off or the
display can't show it; then the text stands as it is."
  (when (roost--decorated-p)
    (roost--mix (face-foreground face nil t) (face-background 'default nil t) (or amount 0.125))))

(defun roost--hairline ()
  "The colour of the lines Roost rules under headings: the text's, faintly."
  (when (roost--decorated-p)
    (roost--mix (face-foreground 'default nil t) (face-background 'default nil t) 0.22)))

(defun roost--ruled (line)
  "LINE, which ends in a newline, with a hairline under it to the window's edge.
Where the display shows one; else LINE as it is."
  (if-let* ((colour (roost--hairline)))
      (let ((line (copy-sequence line)))
        (add-face-text-property 0 (length line)
                                (list :underline (list :color colour :position t) :extend t) t line)
        line)
    line))

(defun roost--banded (line face)
  "LINE, which ends in a newline, on a band of FACE's colour to the window's edge.
For what is wrong and wants you.  Where the display shows one; else
LINE as it is."
  (if-let* ((tint (roost--tint face)))
      (let ((line (copy-sequence line)))
        (add-face-text-property 0 (length line) (list :background tint :extend t) t line)
        line)
    line))

(defun roost--tinted (text face &optional amount)
  "TEXT on a tint of FACE's colour, AMOUNT of it, where the display shows one.
TEXT's own faces stay as they are, over the tint."
  (if-let* ((tint (roost--tint face amount)))
      (let ((text (copy-sequence text)))
        (add-face-text-property 0 (length text) (list :background tint) t text)
        text)
    text))

(defconst roost--line-spacing 0.1
  "The space between the rows of Roost's lists, as a part of a line's height.
With `roost-decorate': rows are easier to tell apart with a little air
between them.  Not in a task's panel, which is read rather than scanned
and has little height to spare beside a terminal.")

(defface roost-dim '((t :inherit shadow))
  "Secondary text: labels, timestamps, prompts.")
(defface roost-key '((t :inherit help-key-binding))
  "Key bindings shown beside actions.")
(defface roost-field '((t))
  "Clickable fields and actions.
They light up under the mouse; inherit `link' to underline them too.")
(defface roost-prose '((t :inherit variable-pitch))
  "What you and the agents wrote: prompts, replies and requests.
Tables and code in them keep the fixed-pitch font.  Inherit `default'
to show all of it in that font.")
(defface roost-status-permission '((t :inherit warning :weight bold))
  "A task waiting for a permission answer in its terminal.")
(defface roost-status-ready '((t :inherit success))
  "A task waiting for your next prompt.")
(defface roost-status-running '((t :inherit shadow))
  "The light of a task whose agent is working.
Dim, as the dot of a task that waits for nothing, but for one that failed:
a light in colour means the task needs you, or something went wrong, and
a plain one would stand out more.")
(defface roost-status-failed '((t :inherit error))
  "A task whose agent failed or disappeared.")
(defface roost-status-inactive '((t :inherit shadow))
  "Stopped, exited, starting, merged or offline tasks.")
(defface roost-pr-open '((t))
  "Face for an open pull request.
Plain: what of it waits on you, such as a failed check, has a colour
of its own." :group 'roost)
(defface roost-pr-draft '((t :inherit shadow))
  "Face for a draft pull request." :group 'roost)
(defface roost-pr-merged '((t))
  "Face for a merged pull request, and for the word of a merged task.
Plain: nothing waits on you, and you retire it when you choose." :group 'roost)
(defface roost-pr-closed '((t :inherit error))
  "Face for a pull request closed without merging." :group 'roost)
(defface roost-selection '((t :inherit completions-highlight :extend t))
  "The line you are on in the sidebar or a task panel, while you are in it.
Their windows have no mode line to show that you are, and the
sidebar's keys act on this row.")
(defface roost-current '((t :inherit region :extend t))
  "The sidebar's row for the task you are working on.
It shows whether or not you are in the sidebar, and `roost-selection'
covers it on the line you are on.")
(defface roost-search-match '((t :inherit match))
  "The words searched for, in search results.")
(defface roost-diff-added '((t))
  "Inserted line counts.
Plain, as the sign tells them apart, so that colour beside a task means
it needs you; inherit `success' to colour them as Magit does.")
(defface roost-diff-removed '((t))
  "Deleted line counts.
Plain, as the sign tells them apart; inherit `error' to colour them.")
(defface roost-note '((t :inherit font-lock-doc-face))
  "Review notes, shown in Magit under the lines they are about.")

;;;; State

(defconst roost--package-directory
  (file-name-directory
   (let ((file (or load-file-name buffer-file-name)))
     ;; Natively compiled code loads from the eln cache, away from scripts/.
     (if (and file (string-suffix-p ".eln" file))
         (or (locate-library "roost") file)
       file)))
  "Directory holding roost.el and scripts/roost_remote.py.")

(defvar roost--tasks (make-hash-table :test 'equal)
  "Cached task records keyed by (HOST ID).")
(defvar roost--installed (make-hash-table :test 'equal)
  "Helper filename installed for each (HOST STATE-DIRECTORY).")
(defvar roost--refreshing (make-hash-table :test 'equal)
  "Hosts with a list request in flight.")
(defvar roost--revisions (make-hash-table :test 'equal)
  "Per-host mutation counter, used to discard stale list replies.")
(defvar roost--list-requests (make-hash-table :test 'equal)
  "How many task lists Roost has asked each host for.")
(defvar roost--pull-requests-asked (make-hash-table :test 'equal)
  "When each host last asked GitHub about its tasks' pull requests.")
(defconst roost--pull-request-interval 120
  "Seconds between background polls that ask GitHub about pull requests.
A merge there leaves no trace on the host for a poll to notice.")
(defvar roost--snapshots (make-hash-table :test 'equal)
  "For each host, the newest request whose task list Roost holds.
Requests are numbered as `roost--list-requests' counts them, so a view
can tell that a list asked for after some moment has arrived.")
(defvar roost--errors (make-hash-table :test 'equal)
  "Last refresh error for each unreachable host.")
(defvar roost--statuses (make-hash-table :test 'equal)
  "Last observed status for each task key, for notifications.
\"prompt\" for one held at a startup prompt, once it was told of.")
(defvar roost--pr-verdicts (make-hash-table :test 'equal)
  "For each task key, what its pull request or work last waited on you for.
As `roost--news-turn' has it, or nil, for notifications.")
(defvar roost--agent-news (make-hash-table :test 'equal)
  "For each task key, a token for the latest change its agent notified of.
An inspection that returns after a newer one notifies of nothing.")
(defvar roost--held-notices nil
  "Notifications held to go together, oldest first; see `roost--hold-notice'.")
(defvar roost--notice-timer nil
  "The timer that sends `roost--held-notices'.")
(defvar roost--seen (make-hash-table :test 'equal)
  "For each task key, its `updatedAt' when you last saw its agent.
A ready agent you have seen since its last event is no longer waiting.")
(defvar roost--turns-sent (make-hash-table :test 'equal)
  "For each task key, the turn sent to its host that its record lacks yet.
See `roost--report-turn'.")
(defvar roost--remembered-hosts nil)
(defvar roost--hosts-loaded nil)
(defvar roost--remembered-projects nil)
(defvar roost--projects-loaded nil)
(defconst roost--sidebar-buffer " *roost sidebar*"
  "Name of the task sidebar buffer; see `roost-sidebar-mode'.
Hidden, as Emacs would otherwise show it across a window that loses its
buffer wherever it isn't on screen, such as a workspace of your own.")

(defvar roost-sidebar-mode)
(defvar roost-task-panel-mode)
(defvar roost-watch-mode)

(defvar roost--current-task nil
  "Key of the task most recently opened.")
(defvar roost--next-unblocked nil
  "Key of the last task `roost-next-waiting' went to that wasn't blocked.
From a blocked task, it goes on from there, or starts again from the
first if that task no longer waits.")
(defvar roost--next-run nil
  "Where you were when you pressed the first `roost-next-waiting' of a run.
A plist: :frame, :workspace and :windows, the frame you were in, its
workspace and its windows; :owner, the key of the task whose workspace
that is, if any, which may be renamed meanwhile; :task and :current,
the frame's task and the task opened last; :buffer, the buffer you were
in; :opened, the keys of the tasks the run opened; and :offered, set
once it has said that none waits, and that pressing it again goes back.
The run goes on while you press it in a task it opened.")
(defvar roost--perspectives (make-hash-table :test 'equal)
  "Names the perspectives of renamed tasks may have, by task key.
perspective.el renames only the current perspective, of each frame's
own; another keeps the name its task had until the task is next opened
in that frame.")
(defvar roost--watch-timer nil)
(defvar roost--watching-on-demand nil
  "Non-nil when Roost began watching after your configuration had loaded.
As when you opened the dashboard: the setup check then suggests
watching from the start of each session.")
(defvar roost--requests nil
  "Live RPC processes.")
(defvar roost--open-generation 0
  "Incremented by each navigation, so slower earlier replies are ignored.")
(defvar-local roost--buffer-task-key nil
  "Task key a task panel buffer belongs to.")

;;;; Task records and hosts

(defun roost--host-label (host)
  "Display label for HOST."
  (or host "local"))

(defun roost--key (task)
  "Qualified identity of TASK."
  (list (alist-get 'host task) (alist-get 'id task)))

(defun roost--field (task field)
  "Read FIELD from TASK."
  (alist-get field task))

(defconst roost--not-text
  ;; Raw bytes in a range of their own: one running into them from below
  ;; matches none of them, and `rx' before Emacs 30 writes it that way.
  (concat "[" (string #xD800 ?- #xDFFF #x110000 ?- #x3FFF7F #x3FFF80 ?- #x3FFFFF) "]")
  "Matches what a string can hold and JSON can't carry.
Mostly the bytes of a file that isn't UTF-8, which Emacs keeps and shows
as \\351.")

(defun roost--shown-text (string)
  "STRING with what JSON can't carry written as Emacs shows it, as \\351.
For what Roost keeps or quotes of its own accord, such as a diff's line."
  (replace-regexp-in-string
   roost--not-text
   (lambda (match)
     (let ((char (aref (string-to-multibyte match) 0)))
       (if (< char #x3FFF80) (format "\\x%X" char) (format "\\%o" (- char #x3FFF00)))))
   string t t))

(defun roost--text-problem (text &optional what)
  "What stops TEXT, which you wrote or quoted, reaching a host, or nil.
As with a control character, it is your text and not Roost's to change.
WHAT names it, if it isn't the prompt."
  (when-let* ((position (string-match-p roost--not-text text)))
    (format "Line %d of the %s holds %s, a byte that isn't text; nothing was sent"
            (1+ (cl-count ?\n text :end position)) (or what "prompt")
            (roost--shown-text (substring text position (1+ position))))))

(defun roost--json-encode (alist)
  "Serialize ALIST as a JSON object, encoding nil values as null.
`json-serialize' would otherwise encode nil as an empty object."
  (when-let* ((problem (seq-some (lambda (entry)
                                   (and (stringp (cdr entry))
                                        (roost--text-problem (cdr entry) (car entry))))
                                 alist)))
    (user-error "%s" problem))
  (json-serialize (mapcar (lambda (entry) (cons (car entry) (or (cdr entry) :null)))
                          alist)))

(defun roost--read-json-list (file &optional unreadable)
  "Return the JSON array in FILE as a list, or UNREADABLE if it can't be read.
JSON null becomes nil."
  (if (not (file-readable-p file))
      unreadable
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          ;; Older versions wrote the local host as {}; as an alist that
          ;; reads back as nil, which is the local host.
          (let ((list (json-parse-buffer :array-type 'list :object-type 'alist :null-object nil)))
            (if (listp list) list unreadable)))
      (error unreadable))))

;; Each file of what Roost remembers is read once, and Emacs works from
;; what it read.  Another Emacs can write it meanwhile, so each change
;; here first takes up what the file holds now, and goes on that.

(defvar roost--file-stamps (make-hash-table :test 'equal)
  "How each file of what Roost remembers was when this Emacs last read or wrote it.
See `roost--file-stamp'.")

(defun roost--file-stamp (file)
  "What moves when FILE is written: its modification time and inode, or nil.
Each write makes a new file, so the inode tells two apart in one tick of
a coarse clock.  Of what FILE leads to, if it is a link."
  (when-let* ((attributes (file-attributes (file-truename file))))
    (list (file-attribute-modification-time attributes)
          (file-attribute-inode-number attributes))))

(defun roost--read-remembered (file)
  "Return the list in FILE, or nil, noting how FILE is for `roost--read-again'."
  (puthash file (roost--file-stamp file) roost--file-stamps)
  (roost--read-json-list file))

(defun roost--read-again (file)
  "Return the list in FILE if it moved since this Emacs read or wrote it.
Otherwise `same', as also when it has gone or can't be read: that is no
other Emacs's doing, which writes it whole, and what this one holds is
better than nothing."
  (let ((stamp (roost--file-stamp file)))
    (if (or (null stamp) (equal stamp (gethash file roost--file-stamps)))
        'same
      (let ((list (roost--read-json-list file 'same)))
        (unless (eq list 'same) (puthash file stamp roost--file-stamps))
        list))))

(defun roost--write-json-list (file list)
  "Write LIST to FILE as a private JSON array, with nil as null.
Through a new file renamed into place, so that nothing reads it half
written, and a write that fails leaves it as it was."
  (make-directory (file-name-directory file) t)
  (let* ((coding-system-for-write 'utf-8-unix)
         ;; What a link, as from your dotfiles, leads to stays where it is.
         (target (file-truename file))
         (new (make-temp-file (concat target ".")))
         stamp)
    (unwind-protect
        (progn
          (with-temp-file new
            (insert (json-serialize (vconcat (mapcar (lambda (item) (or item :null)) list)))))
          ;; Before it goes: once there, it may already be another Emacs's.
          (setq stamp (roost--file-stamp new))
          (rename-file new target t))
      (when (file-exists-p new) (delete-file new)))
    (puthash file stamp roost--file-stamps)))

(defun roost--hosts ()
  "Configured and remembered hosts, without network I/O."
  (unless roost--hosts-loaded
    (setq roost--hosts-loaded t
          roost--remembered-hosts (seq-filter #'string-or-null-p
                                              (roost--read-remembered roost-hosts-file))))
  ;; A copy: `delete-dups' would otherwise drop a configured host from
  ;; the remembered ones, which `append' shares as its tail.
  (delete-dups (append roost-hosts roost--remembered-hosts nil)))

(defun roost--hosts-as-on-file (&rest using)
  "Take up the hosts `roost-hosts-file' holds, if another Emacs changed them.
One it forgot goes here too, as no list would take its tasks away; unless
it is among USING, hosts you are using again, where nil is this machine."
  (let ((watched (roost--hosts))
        (hosts (roost--read-again roost-hosts-file)))
    (unless (eq hosts 'same)
      (setq roost--remembered-hosts (seq-filter #'string-or-null-p hosts))
      (dolist (host (seq-difference watched (append using (roost--hosts))))
        (roost--stop-watching host)
        (message "Roost no longer watches %s, as another Emacs forgot it" (roost--host-label host))))))

(defun roost--remember-host (host)
  "Remember HOST across restarts."
  (roost--hosts-as-on-file host)
  (unless (member host roost--remembered-hosts)
    (push host roost--remembered-hosts)
    (roost--write-json-list roost-hosts-file roost--remembered-hosts)))

(defun roost--directory-host (directory)
  "SSH destination for DIRECTORY, or nil for local."
  (when (file-remote-p directory)
    (let* ((parts (tramp-dissect-file-name directory))
           (host (tramp-file-name-host parts))
           (user (tramp-file-name-user parts))
           (port (tramp-file-name-port parts)))
      (when (or port (tramp-file-name-hop parts))
        (user-error "Use an SSH config alias for custom ports or jump hosts"))
      (if user (concat user "@" host) host))))

(defun roost--remote-directory (task)
  "TASK's worktree as a local or configured TRAMP path."
  (roost--host-directory (roost--field task 'host) (roost--field task 'worktree)))

(defun roost--host-directory (host path)
  "Directory PATH on HOST as a local or configured TRAMP path."
  (if (not host)
      (file-name-as-directory path)
    (let* ((parts (split-string host "@"))
           (user (and (> (length parts) 1) (car parts)))
           (bare (car (last parts)))
           (method (substring-no-properties (tramp-find-method nil user bare))))
      (concat "/" method ":" host ":" (file-name-as-directory path)))))

;;;; Host RPC

(defvar roost--helper-cache nil
  "(ATTRIBUTES FILENAME . SOURCE) for the helper file last read.")

(defun roost--helper ()
  "Return (VERSIONED-FILENAME . SOURCE) for the host helper.
The file is reread only when its modification time or size changes."
  (let* ((file (expand-file-name "scripts/roost_remote.py" roost--package-directory))
         (attributes (file-attributes file))
         (stamp (list (file-attribute-modification-time attributes)
                      (file-attribute-size attributes))))
    (unless (equal (car roost--helper-cache) stamp)
      (setq roost--helper-cache
            (with-temp-buffer
              (insert-file-contents file)
              (cons stamp
                    (cons (concat "remote-"
                                  (substring (secure-hash 'sha256 (current-buffer)) 0 16)
                                  ".py")
                          (buffer-string))))))
    (cdr roost--helper-cache)))

(defun roost--ssh-share-options ()
  "SSH options sharing one connection per host, or nil.
See `roost-ssh-share-connections'."
  (when roost-ssh-share-connections
    (let* ((directory (expand-file-name roost-state-directory))
           (path (expand-file-name "ssh-%C" directory)))
      ;; ssh refuses socket paths of 104 bytes or more (macOS), counting the
      ;; 40-character %C hash and the 17-character suffix of the socket it
      ;; creates first; a longer state directory just doesn't share.
      (when (< (+ (string-bytes path) (- 40 2) 17) 104)
        (ignore-errors (make-directory directory t) (set-file-modes directory #o700))
        (list "-o" "ControlMaster=auto"
              "-o" (concat "ControlPath=" path)
              "-o" "ControlPersist=60")))))

(defun roost--python-command (host code)
  "Local argv executing Python CODE on HOST, without interpolating input.
Python runs isolated (-I), importing nothing from the directory it runs
in, such as the temporary directory here: searching it for each module
took seconds once it held a million files, and a module someone left
there would run as you."
  (if host
      (progn
        (require 'tmux-control nil t)
        (append (list "ssh" "-T" "-o" "BatchMode=yes")
                (or (bound-and-true-p tmux-control-ssh-options)
                    '("-o" "ConnectTimeout=8"))
                (roost--ssh-share-options)
                (list "--" host
                      (concat (when (bound-and-true-p tmux-control-remote-tmux-socket-setup)
                                (concat tmux-control-remote-tmux-socket-setup " && "))
                              "exec python3 -I -c " (shell-quote-argument code)))))
    (list "python3" "-I" "-c" code)))

(defun roost--decode-response (output)
  "Parse the last nonempty line of OUTPUT as the protocol response, an object.
Signal an error saying so when it is anything else, as when a dropped
connection cut it short."
  (let ((line (car (last (split-string output "\n" t "[ \t\r]+")))))
    (unless line (error "The host helper returned no response"))
    (condition-case nil
        (progn (unless (string-prefix-p "{" line) (error "Not an object"))
               (json-parse-string line :object-type 'alist :array-type 'list
                                  :null-object nil :false-object nil))
      ;; Its start, by characters: some, such as accents, take no room.
      (error (error "Roost can't read the host helper's reply: %s"
                    (if (> (length line) 200) (concat (substring line 0 200) "…") line))))))

(defconst roost--pipe-input-limit 4096
  "Bytes of request input written straight to a host command's pipe.
Longer input, such as the helper itself or a long prompt, is read from a
file instead.  Writing it to the pipe would wait, with Emacs frozen,
until ssh had connected and read it: for a host that is down, the whole
connection timeout.")

(defconst roost--error-limit 4000
  "Characters of what a failing host command printed that Roost keeps.")

(defun roost--expire-request (process on-timeout &optional timeout)
  "Kill host request PROCESS, calling ON-TIMEOUT, unless it ends in time.
That is TIMEOUT seconds, or `roost-request-timeout'.  A timer that runs
well after then slept with this computer, through a laptop's sleep or
Power Nap; the request then gets its time again, awake, rather than
failing for want of a reply nobody could send while asleep."
  (let* ((timeout (or timeout roost-request-timeout))
         (deadline (+ (float-time) timeout)))
    (process-put process 'roost-timer
                 (run-at-time timeout nil
                              (lambda ()
                                (when (process-live-p process)
                                  (if (> (float-time) (+ deadline 5))
                                      (roost--expire-request process on-timeout timeout)
                                    (funcall on-timeout)
                                    (delete-process process))))))))

(defun roost--run (host code input success failure &optional timeout)
  "Execute CODE asynchronously on HOST with INPUT.
Call SUCCESS with the result or FAILURE with an error message.  TIMEOUT
is the seconds it may take, if not `roost-request-timeout'."
  (let* ((buffer (generate-new-buffer " *roost-rpc*"))
         (errors (generate-new-buffer " *roost-rpc-errors*"))
         (default-directory temporary-file-directory)
         (command (roost--python-command host code))
         input-file process stderr-pipe finished timed-out)
    (condition-case err
        (progn
          ;; A pipe of our own for stderr: the one `make-process' makes for a
          ;; buffer notes "Process roost-rpc stderr finished" in it, which
          ;; Emacs 32 does before this sentinel reads it.
          (setq stderr-pipe (make-pipe-process :name "roost-rpc stderr" :buffer errors
                                               :noquery t :coding 'utf-8-unix
                                               :sentinel #'ignore))
          (when (> (string-bytes input) roost--pipe-input-limit)
            (setq input-file (make-temp-file "roost-input-"))
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region input nil input-file nil 'silent))
            (setq command (append (list "/bin/sh" "-c" "exec \"$@\" < \"$0\"" input-file) command)))
          (setq process
                (make-process
                 :name "roost-rpc" :buffer buffer :stderr stderr-pipe :noquery t
                 :coding 'utf-8-unix :connection-type 'pipe
                 :command command
                 :sentinel
                 (lambda (proc _event)
                   (when (and (memq (process-status proc) '(exit signal)) (not finished))
                     (setq finished t
                           roost--requests (delq proc roost--requests))
                     (when-let* ((timer (process-get proc 'roost-timer)))
                       (cancel-timer timer))
                     (when input-file (ignore-errors (delete-file input-file)))
                     ;; An integer runs no timers: one that throws, as
                     ;; `with-timeout' does, would leave without a callback.
                     (while (accept-process-output stderr-pipe 0 nil 1))
                     (delete-process stderr-pipe)
                     (unwind-protect
                         (let* ((stdout (with-current-buffer buffer (buffer-string)))
                                (stderr (with-current-buffer errors
                                          (string-trim (buffer-string))))
                                ;; What the host said, decided before either
                                ;; callback runs: an error in one is Roost's,
                                ;; not the host's.
                                (outcome
                                 (condition-case parse-error
                                     (if (= (process-exit-status proc) 0)
                                         (let* ((response (roost--decode-response stdout))
                                                (said (alist-get 'error response)))
                                           (if (eq (alist-get 'ok response) t)
                                               (list success (alist-get 'result response))
                                             ;; Words to show, which callers take apart.
                                             (list failure (if (and (stringp said) (not (string-empty-p said)))
                                                               said
                                                             "Host operation failed"))))
                                       (list failure
                                             (cond (timed-out
                                                    ;; Marked, for a caller that can wait on.
                                                    (propertize
                                                     (format "No reply after %ss; the operation may still finish on the host, so refresh before retrying"
                                                             (or timeout roost-request-timeout))
                                                     'roost-no-reply t))
                                                   ((string-empty-p stderr) "Host operation failed")
                                                   ;; Its end, where a traceback says what
                                                   ;; failed: the sidebar shows it all.
                                                   ((> (length stderr) roost--error-limit)
                                                    (concat "…" (substring stderr (- roost--error-limit))))
                                                   (t stderr))))
                                   (error (list failure (error-message-string parse-error))))))
                           (unless (process-get proc 'roost-dropped)
                             (funcall (car outcome) (cadr outcome))))
                       (kill-buffer buffer)
                       (kill-buffer errors))))))
          (push process roost--requests)
          (roost--expire-request process (lambda () (setq timed-out t)) timeout)
          (unless input-file
            ;; ssh may have exited already, as for an unknown host; then
            ;; the sentinel reports why.
            (ignore-errors
              (process-send-string process input)
              (process-send-eof process))))
      ;; Nothing is left running: a reply to a request you quit, as with
      ;; C-g during g, would come after newer news.  The quit goes on to
      ;; whoever asked, with no callback.
      ((quit error)
       (setq finished t roost--requests (delq process roost--requests))
       (when-let* ((timer (and process (process-get process 'roost-timer))))
         (cancel-timer timer))
       (when (and process (process-live-p process)) (delete-process process))
       (when stderr-pipe (delete-process stderr-pipe))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (when (buffer-live-p errors) (kill-buffer errors))
       (when input-file (ignore-errors (delete-file input-file)))
       (if (eq (car err) 'quit)
           (signal (car err) (cdr err))
         (funcall failure (error-message-string err)))))))

(defun roost--request-wait (host action parameters &optional timeout)
  "Run ACTION with PARAMETERS on HOST and return its result.
For interactive commands that need the answer before prompting.  Signal
a `user-error' with the host's message on failure, or after TIMEOUT
seconds (default 60)."
  (pcase-let ((`(,ok . ,value) (car (roost--requests-wait (list (list host action parameters)) timeout))))
    (if ok value (user-error "%s" value))))

(defun roost--requests-wait (requests &optional timeout)
  "Run REQUESTS at once and return how each went, in order.
Each of REQUESTS is (HOST ACTION PARAMETERS), and each outcome is (t .
RESULT) or (nil . ERROR).  For interactive commands that need the
answers before prompting.  Signal a `user-error' after TIMEOUT seconds
\(default 60)."
  (let ((outcomes (make-vector (length requests) nil)))
    (seq-do-indexed (pcase-lambda (`(,host ,action ,parameters) index)
                      (roost--request host action parameters
                                      (lambda (value) (aset outcomes index (cons t value)))
                                      (lambda (err) (aset outcomes index (cons nil err)))))
                    requests)
    (with-timeout ((or timeout 60)
                   (pcase-let ((`(,host ,action) (nth (seq-position outcomes nil) requests)))
                     (user-error "Roost: %s on %s timed out" action (roost--host-label host))))
      (while (memq nil (append outcomes nil)) (accept-process-output nil 0.05)))
    (append outcomes nil)))

;; The agent starts before Emacs attaches, and tmux would give it 80 by 24.
(defun roost--area-size (area like)
  "The columns and rows AREA, a window or a split of them, can show.
LIKE is a live window in it, which says how much a column and a row of
its text take."
  (let ((width (+ (window-max-chars-per-line like)
                  (floor (- (window-pixel-width area) (window-pixel-width like))
                         (frame-char-width))))
        (height (+ (floor (with-selected-window like (window-screen-lines)))
                   (floor (- (window-pixel-height area) (window-pixel-height like))
                          (frame-char-height)))))
    `((width . ,(max 10 width)) (height . ,(max 10 height)))))

(defun roost--terminal-size (&optional task)
  "The columns and rows of the window TASK's terminal will fill, or nil.
That is the window already showing it; otherwise, in a workspace of its
own, the main area; otherwise the selected main window.  Less the task
panel's columns, when it isn't docked yet and will dock beside the
terminal.  TASK is nil for one not yet created."
  (let ((shown (roost--task-terminal-window task)))
    (when-let* ((like (or shown (roost--selected-main-window))))
      (let* ((area (if (and (not shown) (roost--workspace-backend)) (window-main-window) like))
             (size (roost--area-size area like)))
        ;; Started wider, as from a draft, which has no panel beside it,
        ;; the agent draws its first screen for that width, and tmux
        ;; wraps its lines again as the panel docks.  The panel takes its
        ;; columns from a window as wide as the main area, not from one
        ;; beside another.
        (if (and (not shown) roost-task-panel-mode (roost--side-frame-p)
                 (not (roost--task-panel-window)) (roost--task-panel-fits-p nil)
                 (= (window-total-width area) (window-total-width (window-main-window))))
            `((width . ,(max 10 (- (alist-get 'width size) roost-task-panel-width)))
              (height . ,(alist-get 'height size)))
          size)))))

(defconst roost--install-code
  "import json,os,sys,tempfile
r=os.path.expanduser(%s)
os.makedirs(r,mode=0o700,exist_ok=True)
p=os.path.join(r,%s)
n=%d
if os.path.isfile(p) and os.path.getsize(p)==n:
    os.utime(p)
else:
    d=sys.stdin.buffer.read()
    if len(d)!=n:
        sys.exit('Only %%d of %%d bytes of the helper arrived; nothing was installed'%%(len(d),n))
    fd,t=tempfile.mkstemp(dir=r)
    try:
        with os.fdopen(fd,'wb') as f: f.write(d)
        os.chmod(t,0o700)
        os.replace(t,p)
    except BaseException:
        os.unlink(t)
        raise
print(json.dumps({'ok':True}))"
  "Python that installs the helper from its input: state directory, name, size.
The name is a hash of the helper, and agents' hooks call that file, so one
of the right size stays, as newly used, for `prune_helpers' to go by.  A
connection that drops ends the input, not this: what comes up short
replaces nothing.")

(defun roost--helper-unusable-p (err filename)
  "Whether ERR says the helper FILENAME is gone, or not whole, on its host.
Python couldn't find it, as another Emacs pruned it or the state directory
went, or it isn't the size it should be, as an older Roost's install left
it when cut off.  Either way nothing ran, so asking again can't run an
action twice."
  (and (string-match-p "FileNotFoundError\\|Not whole: " err)
       (string-search filename err)))

(defun roost--request (host action parameters success &optional failure timeout)
  "Run ACTION with PARAMETERS on HOST, installing the versioned helper as needed.
Call SUCCESS with the result, or FAILURE with an error message.  TIMEOUT
is the seconds ACTION may take, if not `roost-request-timeout'."
  (let* ((helper (roost--helper))
         (filename (car helper))
         (size (string-bytes (cdr helper)))
         (root roost-state-directory)
         (installation-key (list host root))
         (failure (or failure
                      (lambda (err) (message "Roost %s: %s" (roost--host-label host) err))))
         ;; Now, as what it can refuse should reach the command that asked,
         ;; rather than a process sentinel once the helper is installed.
         (input (roost--json-encode (append (list (cons 'action action) (cons 'root root))
                                            parameters)))
         (invoke
          (lambda (on-failure)
            (roost--run
             host
             (format "import os,runpy,sys; p=os.path.join(os.path.expanduser(%s),%s); os.path.getsize(p)==%d or sys.exit('Not whole: '+p); sys.argv=[p,'rpc']; runpy.run_path(p,run_name='__main__')"
                     (json-serialize root) (json-serialize filename) size)
             input success on-failure timeout)))
         (install-and-invoke
          (lambda ()
            (roost--run
             host
             (format roost--install-code (json-serialize root) (json-serialize filename) size)
             (cdr helper)
             (lambda (_)
               (puthash installation-key filename roost--installed)
               (funcall invoke failure))
             failure))))
    (if (not (equal (gethash installation-key roost--installed) filename))
        (funcall install-and-invoke)
      (funcall invoke
               (lambda (err)
                 ;; Other failures, such as an unreachable host, keep it.
                 (if (not (roost--helper-unusable-p err filename))
                     (funcall failure err)
                   (remhash installation-key roost--installed)
                   (funcall install-and-invoke)))))))

;;;; Status cache and notifications

(defun roost--emacsclient-command (expression)
  "A shell command evaluating EXPRESSION in this Emacs, or nil without a server."
  (when-let* (((bound-and-true-p server-process))
              ((process-live-p server-process))
              ((bound-and-true-p server-socket-dir))
              (client (seq-find #'file-executable-p
                                (list (expand-file-name "bin/emacsclient" invocation-directory)
                                      (expand-file-name "emacsclient" invocation-directory)
                                      (or (executable-find "emacsclient") "")))))
    (mapconcat #'shell-quote-argument
               (list client "--socket-name" (expand-file-name server-name server-socket-dir)
                     "--no-wait" "--eval" (prin1-to-string expression))
               " ")))

(defun roost--open-from-notification (host id)
  "Open the task with ID on HOST, from a click on its notification.
As a click in Roost does, this quits a question you left open in the
minibuffer, which would hold the task back unseen.  It does so once
Emacs waits for you: the click comes through Emacs's server, which can
run while a command of yours waits, and quitting would end it too.  A
task you open before then is the one shown."
  (when-let* ((task (gethash (list host id) roost--tasks)))
    (select-frame-set-input-focus (selected-frame))
    (let ((generation (cl-incf roost--open-generation)))
      (run-with-idle-timer 0 nil (lambda ()
                                   (when (= generation roost--open-generation)
                                     (roost-open-task task t)))))))

(defun roost--terminal-notifier-arguments (title body task &optional group)
  "Arguments for terminal-notifier to show TITLE and BODY about TASK.
A click opens TASK, given an Emacs server, and a newer notification in
GROUP replaces this one: by default, one about TASK."
  (append (list "-title" title "-message" body)
          (when task
            (append (list "-group" (or group (concat "roost-" (or (roost--field task 'host) "local")
                                                     "-" (roost--field task 'id))))
                    (when-let* ((command (roost--emacsclient-command
                                          ;; Quoted, so they stay data: a click
                                          ;; evaluates this, and an ID a host sent
                                          ;; that isn't a string, such as a JSON
                                          ;; object, would otherwise run as code.
                                          `(roost--open-from-notification
                                            ',(roost--field task 'host) ',(roost--field task 'id)))))
                      (list "-execute" command))))))

(defun roost--notify (title body &optional task group)
  "Display notification TITLE with BODY, about TASK if given.
With terminal-notifier and an Emacs server, a click on it opens TASK,
and a newer notification in GROUP replaces it: by default, one about
TASK."
  (cond ((functionp roost-notify-function)
         (funcall roost-notify-function title body))
        ((executable-find "terminal-notifier")
         (apply #'call-process "terminal-notifier" nil 0 nil
                (roost--terminal-notifier-arguments title body task group)))
        ((eq system-type 'darwin)
         (call-process "osascript" nil 0 nil "-e"
                       (format "display notification %S with title %S" body title)))
        ((fboundp 'notifications-notify)
         (notifications-notify :title title :body body))
        (t (message "%s: %s" title body))))

(defconst roost--measured-fields
  '(diff dirty files size ahead behind update worktreeMissing worktreeBranch worktreeHead worktreePr prStatus
    unpushed gitStamp agentWork merging landed conflicts pr sinceLooked branchTip)
  "A task's fields its host measures for each reply, such as Git statistics.
They are as new as the reply, whatever its `updatedAt': its pull
request too, which the host records as it finds one on GitHub.")

(defun roost--newer-events (task old)
  "TASK, or OLD with TASK's measurements when OLD's `updatedAt' is newer.
A reply its host read before the agent's latest event or the task's
latest change, such as a poll's that took a while, can arrive after one
that read it: it must not bring back what was before, as an agent asking
for permission again or the pane of an agent since stopped.  What its
host measured, such as Git statistics, is as new as anything."
  (let ((new (roost--field task 'updatedAt))
        (had (roost--field old 'updatedAt)))
    (if (not (and (stringp new) (stringp had) (string< new had)))
        task
      (let ((kept (copy-sequence old)))
        (dolist (field roost--measured-fields)
          (when-let* ((cell (assq field task)))
            (setq kept (cons cell (assq-delete-all field kept)))))
        ;; Not what GitHub said of a pull request since recorded otherwise.
        (if (or (assq 'prStatus task) (equal (roost--field task 'pr) (roost--field old 'pr)))
            kept
          (assq-delete-all 'prStatus kept))))))

(defun roost--newer-name (task old)
  "TASK, with OLD's name when OLD was renamed since TASK was read.
A reply its host read before you renamed the task, such as one to
opening it, can arrive after the rename's.  Renaming is no event of the
agent's, which `roost--newer-events' goes by: this keeps the reply from
bringing back the old name, which the task's tab and panel no longer have."
  (let ((renamed (roost--field old 'renamedAt)))
    (if (not (and (stringp renamed)
                  (string< (or (roost--field task 'renamedAt) "") renamed)))
        task
      (dolist (field '(name task renamedAt) task)
        (when-let* ((cell (assq field old)))
          (setq task (cons cell (assq-delete-all field task))))))))

(defun roost--newer-offers (task old)
  "TASK, with OLD's offers when they changed since TASK was read.
An offer made or taken is no event of the agent's, which
`roost--newer-events' goes by: this keeps a reply read before you took
an offer from bringing it back, and one read before an offer was made
from hiding it."
  (let ((changed (roost--field old 'offersAt)))
    (if (not (and (stringp changed)
                  (string< (or (roost--field task 'offersAt) "") changed)))
        task
      (dolist (field '(offers offersAt) task)
        (setq task (assq-delete-all field task))
        (when-let* ((cell (assq field old)))
          (setq task (cons cell task)))))))

(defun roost--newer-look (task old)
  "TASK, with OLD's record of where you last looked when that is newer.
A reply its host read before you last looked at the task, such as a
poll's, can arrive after the look's: it must not bring back the look
before, which would count again what you have looked at since.  Nor
must a reply with a newer look lose it for an older agent event."
  (let ((looked (roost--field old 'looked)))
    (if (string< (or (alist-get 'at (roost--field task 'looked)) "") (or (alist-get 'at looked) ""))
        (cons (cons 'looked looked) (assq-delete-all 'looked task))
      task)))

(defun roost--kept-reviews (task old)
  "TASK, with OLD's pull request status where its host's review query failed.
Of the same pull request at the same head and base, what the forge last
said stands, whole, as when it doesn't answer at all: without its reviews
the task's word would go, and come back as news, and beside newer checks
they could make a word nobody said."
  (dolist (field '(prStatus worktreePr) task)
    (let ((status (roost--field task field))
          (had (roost--field old field)))
      (when (and had (alist-get 'reviewsFailed status)
                 ;; A worktree's says which it is of itself.
                 (or (not (eq field 'prStatus))
                     (equal (alist-get 'number (roost--field task 'pr)) (alist-get 'number (roost--field old 'pr))))
                 (seq-every-p (lambda (key) (equal (alist-get key status) (alist-get key had)))
                              '(number head base state draft)))
        ;; Of the branch here, this reply is the newer.
        (setq task (cons (cons field (append (seq-filter (lambda (entry) (memq (car entry) '(branch tip unpushed)))
                                                         status)
                                             (seq-remove (lambda (entry) (memq (car entry) '(branch tip unpushed)))
                                                         had)))
                         (assq-delete-all field task)))))))

(defvar roost--went (make-hash-table :test 'equal)
  "Tasks that left `roost--tasks', by key, as a list or a reply said they went.
A reply to create read before then can come after.")

(defun roost--cache-task (host task)
  "Cache TASK from HOST and notify only on attention transitions."
  (setf (alist-get 'host task) host)
  (dolist (field '(pushed alreadySent alreadyMade note))
    (setq task (assq-delete-all field task)))
  (when-let* ((old (gethash (roost--key task) roost--tasks)))
    ;; Looks and the agent's events move apart: the newer of each counts.
    (let ((looked (roost--newer-look old task)))
      (setq task (roost--kept-reviews
                  (roost--newer-look (roost--newer-offers (roost--newer-name (roost--newer-events task old) old)
                                                          old)
                                     looked)
                  old))))
  (let* ((key (roost--key task))
         (old (gethash key roost--tasks))
         (had-merged (and old (roost--pr-merges old)))
         (status (roost--field task 'status))
         ;; Only time shows an agent held at a startup prompt, so what is
         ;; noted of it is "prompt", until it is no longer starting: an
         ;; event that leaves it so makes it read as newly started.
         (noted (gethash key roost--statuses))
         (previous (if (equal noted "prompt") "starting" noted))
         (prompt (and (equal status "starting") (roost--held-starting-p task)))
         (new-stop (and (equal status "ready")
                        (equal (roost--field task 'lastEvent) "Stop")
                        (not (equal (roost--field task 'updatedAt)
                                    (roost--field old 'updatedAt))))))
    ;; Quiet polls skip Git and the latest reply; keep the last full refresh's.
    ;; Not what GitHub said of a pull request since recorded otherwise, as
    ;; by another Emacs: closed, or another in its place.
    (dolist (field '(diff dirty files size ahead behind worktreeMissing worktreeBranch worktreeHead worktreePr
                            prStatus unpushed lastMessage gitStamp agentWork merging landed conflicts sinceLooked
                            branchTip))
      (unless (or (assoc field task)
                  (and (eq field 'prStatus)
                       (not (equal (roost--field task 'pr) (roost--field old 'pr)))))
        (when (assoc field old) (push (assoc field old) task))))
    (if (not (member status '("retired" "forgotten" "discarded")))
        (puthash key task roost--tasks)
      (remhash key roost--tasks)
      (puthash key t roost--went)
      (roost--remove-notes (lambda (note) (equal (roost--note-key note) key))))
    ;; Renamed, here or from another Emacs: its workspace and the panels
    ;; follow, before the views are drawn.
    (when (and old (gethash key roost--tasks)
               (not (equal (roost--field old 'name) (roost--field task 'name))))
      (roost--rename-workspace old task)
      (roost--name-panels))
    ;; Record the status before notifying, which may cache this task again.
    (puthash key (if (or prompt (and (equal status "starting") (equal noted "prompt"))) "prompt" status)
             roost--statuses)
    (let ((turn (roost--news-turn task))
          (had (gethash key roost--pr-verdicts 'unknown))
          ;; Not when you are looking at it already.
          (unwatched (lambda ()
                       (not (when-let* ((watched (roost--watched-task)))
                              (equal (roost--key watched) key))))))
      ;; Unknown until measured: a quiet list says nothing of what waits, so
      ;; what was there all along would read as news from the first that does.
      (cond ((not (gethash key roost--tasks))
             (remhash key roost--pr-verdicts)
             (remhash key roost--agent-news))
            ((or (roost--judged-p task) (not (eq had 'unknown))) (puthash key turn roost--pr-verdicts)))
      ;; One held about it that is so no longer goes no more, though the
      ;; task may come to be so again before it would go.
      (when-let* ((held (seq-find (lambda (notice) (equal (plist-get notice :key) key)) roost--held-notices)))
        (unless (roost--notice-still-p held (gethash key roost--tasks))
          (roost--drop-notices key)))
      ;; A pull request or work that comes to wait on you is news, whatever
      ;; its agent last said; one there when Roost first measured the task
      ;; is not, nor one that comes as you stop its agent.  Before the
      ;; agent's news, which replaces it when both come.
      (when (and roost-notify turn (not (eq had 'unknown)) (not (equal had turn))
                 (not (and (equal status "stopped") (not (equal previous "stopped"))))
                 (funcall unwatched))
        (roost--hold-notice task turn (concat (roost--host-label host) " · " (roost--turn-reason task turn))))
      (when (and roost-notify previous
                 (or (not (equal previous status)) new-stop)
                 ;; An agent that has just started waits for a prompt, which
                 ;; is no news; one that asks or fails at once is, and polls
                 ;; while Emacs is in the background may see only that.
                 (or (not (equal previous "starting")) (not (equal status "ready")) new-stop)
                 (not (roost--just-started-p task))
                 (member status '("ready" "permission" "failed" "crashed" "exited"))
                 (funcall unwatched))
        (roost--notify-attention host task status))
      ;; Once, as it comes to read so.
      (when (and roost-notify previous prompt (not (equal noted "prompt")) (funcall unwatched))
        (roost--notify-attention host task "prompt")))
    (when (and previous (not (equal previous status)))
      (roost--run-task-hook 'roost-task-status-functions task previous status))
    (when (gethash key roost--tasks)
      (roost--report-turn task))
    ;; Another pull request merged, as a second one on the task, is another
    ;; merge, at another head or into another branch.
    (dolist (merge (roost--pr-merges task))
      (unless (member merge had-merged)
        ;; One there when Roost first saw the task is no news, nor when `m'
        ;; then retires it.
        (roost--report-merge task (car merge) (cdr merge) (not old))))
    task))

(defun roost--went-p (key listed)
  "Whether the task with KEY went since Roost asked its host about it.
LISTED is what Roost listed then: nil for a task it didn't list, which
is yet to come rather than gone."
  (and listed (not (gethash key roost--tasks))))

(defun roost--cache-reply (host task listed)
  "Cache TASK, as HOST replied about it, and return it, unless it went meanwhile.
LISTED is as for `roost--went-p'.  A reply its host read before the task
went can come after: to opening it while another Emacs retired it, or
after you forgot its host, whose tasks no list would ever take away
again.  The task then stays gone, and what Roost returns goes no further
than the command that asked.  A reply that says it went is taken in as
ever."
  (if (and (roost--went-p (list host (roost--field task 'id)) listed)
           (not (member (roost--field task 'status) '("retired" "forgotten" "discarded"))))
      (cons (cons 'host host) (assq-delete-all 'host task))
    (roost--cache-task host task)))

(defun roost--pr-merges (task)
  "Where TASK's pull requests merged, as a list of (HEAD . BRANCH).
HEAD is nil when not known, and BRANCH a pull request's base, which an
agent's own can choose, or else TASK's integration branch.  Those that
merged at the task's tip count while another, open, is the one shown."
  (let* ((status (roost--field task 'prStatus))
         (pr (roost--field task 'pr))
         (head (alist-get 'mergedHead pr)))
    (delete-dups
     (append (when (eq (roost--pr-state task) 'merged)
               (list (cons (or (alist-get 'head status) (alist-get 'head pr))
                           (or (alist-get 'base status) (alist-get 'base pr)
                               (roost--field task 'integrationBranch)))))
             (when head
               (mapcar (lambda (base) (cons head base))
                       (or (alist-get 'mergedBases pr) (list (roost--field task 'integrationBranch)))))))))

(defvar roost--merges-reported (make-hash-table :test 'equal)
  "The merges reported for each task, by task key, as (COMMIT . BRANCH).")

(defun roost--report-merge (task commit branch &optional quietly)
  "Run `roost-task-merged-functions' for TASK, merged at COMMIT into BRANCH.
Once for each COMMIT and BRANCH: a merge on GitHub and `m' can both see
one, as when a poll finds its pull request merged while `m' runs.
Commits made after a pull request merged, which `m' then merges, are
another merge, as is the same commit merged into another branch.
QUIETLY records the merge as reported without running them."
  (let* ((key (roost--key task))
         (reported (gethash key roost--merges-reported)))
    (unless (and commit (member (cons commit branch) reported))
      (when commit (puthash key (cons (cons commit branch) reported) roost--merges-reported))
      (unless quietly
        (roost--run-task-hook 'roost-task-merged-functions task branch)))))

(defun roost--run-task-hook (hook &rest arguments)
  "Call each function on HOOK with ARGUMENTS, reporting any that fails.
A function of yours that fails must not keep Roost from taking in what
a host said, nor the other functions from running."
  (apply #'run-hook-wrapped hook
         (lambda (function &rest arguments)
           (condition-case err
               (apply function arguments)
             (error (message "Roost: %s failed: %s" function (error-message-string err))))
           nil)
         arguments))

(defun roost--notify-attention (host task status)
  "Notify that TASK on HOST became STATUS.
A permission request goes at once, since its agent can do nothing until
you answer; the rest are held to go together, by `roost--hold-notice', as
\"prompt\" is, an agent seemingly held at a startup prompt, which goes no
more if it was only slow to start.
A ready agent or one asking permission is inspected first, since quiet
polls leave out its latest reply, so the notification can say what it
finished or wants; unless its agent changed again by then, which
notifies of itself."
  (let* ((name (if (equal status "prompt") status (roost--status-name task)))
         (label (roost--host-label host))
         (key (roost--key task))
         (news (puthash key (list status) roost--agent-news))
         (send (lambda (task body)
                 (cond ((not (eq (gethash key roost--agent-news) news)))
                       ((equal status "permission")
                        ;; It replaces one held about the task, which is older.
                        (roost--drop-notices key)
                        (roost--notify (roost--notice-title task name) body task))
                       ;; Seen while it was inspected, as when `n' opened it.
                       ((not (roost--seen-p task))
                        (roost--hold-notice task name body (if (equal status "prompt") "starting" status)))))))
    ;; What was held about the task is older, even while it is inspected.
    (roost--drop-notices key)
    (if (not (member status '("ready" "permission")))
        (funcall send task (if-let* ((error (roost--field task 'error)))
                               (concat label " · " (truncate-string-to-width error 160 nil nil "…"))
                             label))
      (roost--request
       host "inspect" (list (cons 'id (roost--field task 'id)))
       (lambda (current)
         (setq current (roost--cache-reply host current t))
         (roost--redraw)
         (funcall send current
                  (if-let* ((reply (or (roost--permission-request current)
                                       (roost--last-message-summary current))))
                      (concat label " · " (truncate-string-to-width reply 160 nil nil "…"))
                    label)))
       (lambda (_error) (funcall send task label))))))

;;;; Notifications held to go together

;; A permission request notifies at once: its agent can do nothing until
;; you answer.  The rest, finished turns, failures and pull requests or
;; work that wait on you, gather across tasks into one notification that
;; names the most urgent and counts the others.  Five agents that each
;; finish a turn every ten minutes would otherwise send more than anyone
;; heeds, and bury the requests among them.

(defconst roost--notice-gather 60
  "Seconds notifications that block no agent gather before they go, as one.
From the first one held: those that come meanwhile go with it.")

(defconst roost--notice-group "roost-held"
  "The terminal-notifier group of held notifications: a newer one replaces it.")

;; Defined with choosing a task, below.
(defvar roost--pr-turns)

(defun roost--notice-title (task status)
  "A notification's title, that TASK is STATUS."
  (format "%s — %s" (roost--field task 'name) status))

(defun roost--hold-notice (task status body &optional recorded)
  "Hold a notification that TASK became STATUS, saying BODY, to go with others.
It replaces one held about TASK, as newer, and goes once
`roost--notice-gather' seconds have passed since the first one held,
unless you have seen TASK by then, or it is STATUS no longer.  News of
its agent's comes with RECORDED, the status its host recorded: while
that lasts, so does the notification, named as the task is by then, as
\"failed\" for an \"error\" whose agent has since gone."
  (let ((key (roost--key task)))
    (roost--drop-notices key)
    (setq roost--held-notices
          (append roost--held-notices
                  (list (list :key key :status status :recorded recorded :body body
                              :seen (roost--seen-p task)))))
    (unless (timerp roost--notice-timer)
      (setq roost--notice-timer (run-at-time roost--notice-gather nil #'roost--send-notices)))))

(defun roost--drop-notices (key)
  "Drop the notification held about the task with KEY, if any."
  (setq roost--held-notices
        (seq-remove (lambda (notice) (equal (plist-get notice :key) key)) roost--held-notices)))

(defun roost--notice-still-p (notice task)
  "Whether TASK, as cached, is still as held NOTICE about it says.
Nil when TASK is: it went, retired or no longer listed by its host."
  (when task
    (if-let* ((recorded (plist-get notice :recorded)))
        (equal recorded (roost--field task 'status))
      (equal (plist-get notice :status) (roost--news-turn task)))))

(defun roost--notice-holds-p (notice watched)
  "Whether held NOTICE is news still: its task is as it says, and unseen.
Its task may have gone meanwhile, or moved on, or you may have seen it,
here or in another Emacs, or be looking at it now: WATCHED is the key
of the task you look at."
  (let ((task (gethash (plist-get notice :key) roost--tasks)))
    (and (roost--notice-still-p notice task)
         (not (and (roost--seen-p task) (not (plist-get notice :seen))))
         (not (equal watched (plist-get notice :key))))))

(defun roost--send-notices ()
  "Send the notifications held as one, about the most urgent of their tasks.
It counts the others by status, and a click on it opens that task."
  ;; Called before its time, the timer must not go again.
  (when (timerp roost--notice-timer) (cancel-timer roost--notice-timer))
  (setq roost--notice-timer nil)
  (let* ((watched (when-let* ((task (roost--watched-task))) (roost--key task)))
         (notices (and roost-notify
                       (mapcar (lambda (notice)
                                 ;; Named as its task is now.
                                 (if (or (not (plist-get notice :recorded))
                                         (equal (plist-get notice :status) "prompt"))
                                     notice
                                   (plist-put (copy-sequence notice) :status
                                              (roost--status-name (gethash (plist-get notice :key) roost--tasks)))))
                               (seq-filter (lambda (notice) (roost--notice-holds-p notice watched))
                                           roost--held-notices)))))
    (setq roost--held-notices nil)
    (when notices
      ;; As `roost-next-waiting' goes, the first held first among equals.
      (let* ((sorted (seq-sort-by (lambda (notice) (roost--status-rank (plist-get notice :status)))
                                  #'< notices))
             (top (car sorted))
             (task (gethash (plist-get top :key) roost--tasks))
             (counts nil))
        (dolist (notice (cdr sorted))
          (cl-incf (alist-get (plist-get notice :status) counts 0 nil #'equal)))
        (roost--notify (roost--notice-title task (plist-get top :status))
                       (concat (plist-get top :body)
                               (when counts
                                 (format "\n+%d more: %s" (length (cdr sorted))
                                         (mapconcat (lambda (count) (format "%d %s" (cdr count) (car count)))
                                                    (nreverse counts) ", "))))
                       task roost--notice-group)))))

(defun roost--apply-snapshot (host tasks &optional request)
  "Replace only HOST's cached tasks with a successful snapshot TASKS.
REQUEST is the number of the list request that TASKS answers, as counted
in `roost--list-requests'; without one, TASKS count as asked for now."
  (let ((keys (mapcar (lambda (task) (list host (roost--field task 'id))) tasks)))
    (maphash (lambda (key _)
               (when (and (equal (car key) host) (not (member key keys)))
                 (remhash key roost--tasks)
                 (puthash key t roost--went)
                 (remhash key roost--statuses)
                 (remhash key roost--pr-verdicts)
                 (remhash key roost--agent-news)
                 (remhash key roost--seen)
                 (remhash key roost--turns-sent)
                 (remhash key roost--merges-reported)
                 (roost--remove-notes (lambda (note) (equal (roost--note-key note) key)))))
             roost--tasks)
    (mapc (lambda (task) (roost--cache-task host task)) tasks)
    (puthash host (max (or request (puthash host (1+ (gethash host roost--list-requests 0)) roost--list-requests))
                       (gethash host roost--snapshots 0))
             roost--snapshots)
    (remhash host roost--errors)))

(defun roost--task-states (host)
  "HOST's tasks, cached, as ID to (STATUS UPDATED-AT GIT-STAMP PR LOOKED).
Each agent hook event, such as finishing a tool, moves UPDATED-AT; Git
commands in the worktree, such as your commit, change GIT-STAMP.  PR is
the state its host recorded of its pull request, which another Emacs
may have changed: closed, it no longer says whether the task conflicts.
LOOKED is when you last looked at it, from this Emacs or another, which
what changed since is measured against."
  (let (states)
    (maphash (lambda (key task)
               (when (equal (car key) host)
                 (push (list (cadr key) (roost--field task 'status)
                             (roost--field task 'updatedAt) (roost--field task 'gitStamp)
                             (alist-get 'state (roost--field task 'pr))
                             (alist-get 'at (roost--field task 'looked)))
                       states)))
             roost--tasks)
    states))

(defvar roost--full-refresh-pending (make-hash-table :test 'equal)
  "Hosts whose full refresh was requested while another request was in flight.")
(defvar roost--measures-owed (make-hash-table :test 'equal)
  "What each host is to measure after its next good poll: t for every task, or IDs.
What a list that failed or was dropped would have measured, and tasks a
list brought news of without measuring them.  From a poll, rather than
the end of a list: so a host that always fails isn't asked in a loop,
and two busy agents aren't measured back to back.  Owed until measured:
taken up again at once, then, if that fails too, now and then, as
`roost--measures-due' says, so a list too slow ever to answer holds up
few polls.")
(defvar roost--measures-due (make-hash-table :test 'equal)
  "When each host's quiet polls take up what it owes again, as (COUNT . TIME).
COUNT is the measurements lost in a row since one was taken up again,
and TIME the `float-time' from which polls take it up.")
(defvar roost--failures (make-hash-table :test 'equal)
  "Consecutive refresh failures per host, as (COUNT . RETRY-AFTER).")

(defun roost--owe-measuring (table host ids)
  "Note in TABLE that HOST is to measure IDS, or every task if nil."
  (let ((owed (gethash host table)))
    (puthash host (if (or (null ids) (eq owed t)) t (seq-union owed ids)) table)))

(defun roost--refresh-host (host quiet &optional ids)
  "Refresh HOST asynchronously.
QUIET skips Git statistics; otherwise IDS, if non-nil, limits them to
those tasks, and what is owed, as `roost--measures-owed' has it, goes too."
  (if (gethash host roost--refreshing)
      ;; Run the requested full refresh once the in-flight poll returns.
      (unless quiet (roost--owe-measuring roost--full-refresh-pending host ids))
    (puthash host t roost--refreshing)
    (let* ((owed (unless quiet (gethash host roost--measures-owed)))
           (ids (if (and owed ids) (unless (eq owed t) (seq-union ids owed)) ids))
           (request (puthash host (1+ (gethash host roost--list-requests 0)) roost--list-requests))
           (revision (gethash host roost--revisions 0))
           (last-asked (gethash host roost--pull-requests-asked))
           ;; Full refreshes ask GitHub too, and quiet polls now and then.
           (pull-requests (if quiet
                              (> (- (float-time) (or last-asked 0)) roost--pull-request-interval)
                            (not ids)))
           ;; Nothing came of this list, so what it was for is still to do.
           ;; UNTRIED, it was no try: its reply was stale, or it never went.
           (lost (lambda (&optional untried)
                   (unless quiet
                     (roost--owe-measuring roost--measures-owed host ids)
                     ;; What was owed had its one more try: polls take it up
                     ;; again only now and then, first after as long as
                     ;; they wait to ask the forge, then twice as long each
                     ;; time, up to eight times.
                     (when (and owed (not untried))
                       (let ((count (1+ (or (car (gethash host roost--measures-due)) 0))))
                         (puthash host (cons count (+ (float-time) (* roost--pull-request-interval
                                                                      (expt 2 (min 3 (1- count))))))
                                  roost--measures-due))))
                   (when pull-requests
                     (if last-asked
                         (puthash host last-asked roost--pull-requests-asked)
                       (remhash host roost--pull-requests-asked)))))
           asked finished
           ;; Once: the refresh it starts next has the flag then.
           (finish (lambda ()
                     (unless finished
                       (setq finished t)
                       (remhash host roost--refreshing)
                       (when-let* ((pending (gethash host roost--full-refresh-pending)))
                         (remhash host roost--full-refresh-pending)
                         (roost--refresh-host host nil (unless (eq pending t) pending)))))))
      (when owed (remhash host roost--measures-owed))
      (when pull-requests (puthash host (float-time) roost--pull-requests-asked))
      (let ((failed
             (lambda (err)
               (unwind-protect
                   ;; Not for a host forgotten meanwhile, which is no longer
                   ;; yours to hear about.
                   (when (member host (roost--hosts))
                     ;; Once per outage: ssh words a sleeping host's failure differently
                     ;; from one poll to the next, and the sidebar shows it meanwhile.
                     ;; Its last line says what failed; ssh's earlier ones say less, such
                     ;; as that a shared connection broke.  The sidebar's tooltip has all.
                     (unless (gethash host roost--errors)
                       (message "Roost %s: %s (M-x roost-doctor checks this host)" (roost--host-label host)
                                (car (last (split-string err "\n" t "[ \t\r]+")))))
                     (puthash host err roost--errors)
                     (funcall lost)
                     ;; Back off from unreachable hosts, up to a minute between attempts.
                     (let ((count (1+ (or (car (gethash host roost--failures)) 0))))
                       (puthash host (cons count (+ (float-time)
                                                    (min 60 (* roost-watch-interval (expt 2 (1- count))))))
                                roost--failures))
                     (roost--redraw))
                 (funcall finish)))))
        ;; Stopped before a callback is in place, as with no helper to read
        ;; or by a quit, nothing else ends the refresh: the host would
        ;; never be asked again.
        (unwind-protect
            (progn
              (roost--request
               host "list" `((full . ,(cond (quiet :false) (ids (vconcat ids)) (t t)))
                             ,@(when (and quiet pull-requests) '((pullRequests . t))))
               ;; Each ends the refresh even if drawing what it found fails, or
               ;; the host would never be asked again.
               (lambda (tasks)
                 (if (not (roost--task-list-p tasks))
                     (funcall failed "Roost can't read the tasks the host helper listed")
                   (unwind-protect
                       (progn
                         (remhash host roost--failures)
                         (remhash host roost--errors)
                         ;; A newer mutation must win over a stale list reply, and a host
                         ;; forgotten meanwhile stays forgotten.
                         (cond
                          ((not (member host (roost--hosts))))
                          ((/= revision (gethash host roost--revisions 0)) (funcall lost t))
                          (t
                           (let ((before (roost--task-states host)))
                             ;; What was owed is measured.
                             (when owed (remhash host roost--measures-due))
                             (roost--apply-snapshot host tasks request)
                             (with-demoted-errors "Roost: %S" (roost--compose-listed host tasks))
                             ;; Quiet polls leave out Git statistics, as does a list of
                             ;; some tasks for the rest.  An agent that reported something,
                             ;; such as finishing an edit, may have changed files, and a
                             ;; commit moves the task's Git stamp: measure those tasks once
                             ;; this poll is done, with what is owed.  What a list of some
                             ;; brought waits for the next: two busy agents would otherwise
                             ;; keep this going.
                             (let ((changed (seq-difference
                                             (seq-keep (lambda (state)
                                                         (unless (equal state (assoc (car state) before))
                                                           (car state)))
                                                       (roost--task-states host))
                                             ids))
                                   (owed (and (< (or (cdr (gethash host roost--measures-due)) 0) (float-time))
                                              (gethash host roost--measures-owed))))
                               (cond ((and quiet (or changed owed))
                                      (roost--refresh-host host nil (or changed (unless (eq owed t) owed))))
                                     ((and ids changed)
                                      (roost--owe-measuring roost--measures-owed host changed)))))))
                         (roost--redraw))
                     (funcall finish))))
               failed)
              (setq asked t))
          (unless asked
            (funcall lost t)
            (funcall finish)))))))

(defun roost--task-list-p (tasks)
  "Whether TASKS, as a host listed them, is a list of tasks, each with an ID."
  (and (proper-list-p tasks)
       (seq-every-p (lambda (task)
                      (and (consp task) (proper-list-p task) (stringp (alist-get 'id task))))
                    tasks)))

;;;###autoload
(defun roost-forget-host (host)
  "Stop watching HOST, which Roost remembered when you first used it.
Its tasks' terminals, panels and workspaces close.  Agents there keep
running, and using the host again watches it again.
Hosts in `roost-hosts' are watched until you take them out of it."
  (interactive
   (progn
     (roost--hosts)
     (let ((hosts (mapcar (lambda (host) (cons (roost--host-label host) host))
                          (seq-remove (lambda (host) (member host roost-hosts))
                                      roost--remembered-hosts))))
       (unless hosts (user-error "Roost remembers no hosts beyond `roost-hosts'"))
       (list (cdr (assoc (completing-read "Forget host: " hosts nil t) hosts))))))
  (roost--hosts)
  (let ((tasks (seq-filter (lambda (task) (equal (roost--field task 'host) host)) (roost-tasks))))
    (when (or (null tasks)
              (yes-or-no-p (format "%d task%s on %s will no longer show; their agents keep running.  Forget %s? "
                                   (length tasks) (if (cdr tasks) "s" "")
                                   (roost--host-label host) (roost--host-label host))))
      (roost--hosts-as-on-file)
      (setq roost--remembered-hosts (delete host roost--remembered-hosts))
      (roost--write-json-list roost-hosts-file roost--remembered-hosts)
      (roost--stop-watching host)
      (message "Roost no longer watches %s" (roost--host-label host)))))

(defun roost--stop-watching (host)
  "Drop HOST's tasks from Roost, which no longer asks it about them."
  (let ((tasks (seq-filter (lambda (task) (equal (roost--field task 'host) host)) (roost-tasks))))
    ;; Their terminals, panels and workspaces go too, as a retired
    ;; task's do; their agents run on, and opening one again connects.
    (roost--discard-terminal (mapcan #'roost--release-terminal tasks))
    (mapc #'roost--retired-workspace tasks)
    (dolist (task tasks)
      (remhash (roost--key task) roost--tasks)
      (remhash (roost--key task) roost--statuses)
      (remhash (roost--key task) roost--pr-verdicts)
      (remhash (roost--key task) roost--agent-news)
      (remhash (roost--key task) roost--turns-sent))
    (remhash host roost--errors)
    (remhash host roost--failures)
    (remhash host roost--measures-owed)
    (remhash host roost--measures-due)
    (roost--redraw)))

(defun roost-refresh (&optional quiet)
  "Refresh hosts asynchronously, including Git statistics.
QUIET (used by background polls) skips Git statistics and hosts that
recently failed."
  (interactive)
  (dolist (host (roost--hosts))
    (unless (and quiet (> (or (cdr (gethash host roost--failures)) 0) (float-time)))
      (roost--refresh-host host quiet))))

(defun roost-tasks ()
  "Cached tasks across hosts, without network I/O.
They are in order of host and name."
  (let (keyed)
    ;; Each task's key made once, rather than two for each comparison:
    ;; views call this for each of their rows.
    (maphash (lambda (_ task)
               (push (cons (concat (roost--host-label (roost--field task 'host)) (roost--field task 'name))
                           task)
                     keyed))
             roost--tasks)
    (mapcar #'cdr (sort keyed (lambda (a b) (string-lessp (car a) (car b)))))))

;;;; Choosing a task

(defconst roost--pr-turns '("ci failed" "comments" "to merge")
  "Statuses of a task whose pull request waits on you; see `roost--pr-turn'.")

(defun roost--just-started-p (task)
  "Whether TASK's agent has done nothing since it started, as when resumed.
It waits at its prompt, as it did before it stopped or crashed, and so
waits for nothing from you that you don't know: you started it.  Its
host's history counts it so too (START_EVENTS)."
  (and (equal (roost--field task 'status) "ready")
       (member (roost--field task 'lastEvent) '("SessionStart" "session_start"))))

(defconst roost--status-order
  '("permission" "prompt" "ready" "interrupted" "error" "failed" "crashed" "exited"
    "ci failed" "comments" "conflicts" "to merge" "running" "background" "merged" "idle"
    "starting" "stopped")
  "Attention statuses from most to least in need of attention.")

(defun roost--seen-p (task)
  "Whether you have seen TASK's agent since its last event.
Here or in another Emacs: the task's host records it too.  An agent that
has done nothing since it started counts as seen, as `roost--just-started-p'
says: it waits at its prompt, as one you resumed does."
  (or (roost--just-started-p task)
      (when-let* ((updated (roost--field task 'updatedAt)))
        (or (equal (gethash (roost--key task) roost--seen) updated)
            (equal (roost--field task 'seen) updated)))))

(defun roost--held-starting-p (task)
  "Whether TASK, starting, has been so too long, as at a startup prompt."
  (> (or (roost--seconds-since (roost--field task 'updatedAt)) 0) roost-startup-grace))

(defun roost--attention-status (task)
  "TASK's status for attention.
That is \"prompt\" when it has been starting too long, and \"idle\" when
it is ready and you have seen it since, rather than \"ready\"."
  (let ((status (roost--display-status task)))
    (cond ((and (equal status "starting") (roost--held-starting-p task))
           "prompt")
          ((and (member status '("ready" "interrupted")) (roost--seen-p task))
           "idle")
          (t status))))

(defun roost--blocked-p (task)
  "Whether TASK's agent can't go on without you: it asks, or is stuck starting."
  (member (roost--attention-status task) '("permission" "prompt")))

(defun roost--waiting-p (task)
  "Whether TASK waits for you.
Its agent asks something, or finished, failed, crashed or exited since
you last saw it, or its pull request waits on you, or its work conflicts
with the branch it merges into."
  (let ((status (roost--attention-status task)))
    (or (member status '("permission" "prompt" "ready" "interrupted" "conflicts"))
        (member status roost--pr-turns)
        (and (member status '("error" "failed" "crashed" "exited"))
             (not (roost--seen-p task))))))

(defun roost--mark-seen (task)
  "Record that you have seen TASK's agent as it is now.
Its host records it too, for your other Emacs and the next session.
A notification held about it goes no more: you have seen it."
  (let ((key (roost--key task))
        (updated (roost--field task 'updatedAt)))
    (roost--drop-notices key)
    (unless (or (null updated) (roost--seen-p task))
      (puthash key updated roost--seen)
      ;; Only where seeing it stops it waiting: a working agent's every
      ;; event would otherwise send its host a request.  Stopped too: two
      ;; Emacs would otherwise judge what of it waits on you differently,
      ;; and each undo the other's turn.
      (when (member (roost--status-name task)
                    '("ready" "interrupted" "error" "failed" "crashed" "exited" "stopped"))
        (roost--record-seen task updated)))))

(defun roost--record-seen (task updated)
  "Record on TASK's host that you saw its agent as of UPDATED."
  (roost--request (roost--field task 'host) "seen"
                  (list (cons 'id (roost--field task 'id)) (cons 'updatedAt updated))
                  #'ignore #'ignore))

(defun roost--terminal-shows-p (task panes)
  "Whether the current terminal shows one of PANES in TASK's tmux session.
tmux numbers panes afresh when its server restarts, so a task whose
agent died with the server may still list a pane ID that now belongs
to another task.  Each task has a session of its own."
  (and (fboundp 'tmux-control-active-pane)
       (member (tmux-control-active-pane) (delq nil panes))
       (equal (roost--field task 'host) (tmux-control-buffer-host))
       (equal (roost--field task 'socket) (tmux-control-buffer-socket-name))
       (equal (roost--field task 'session) (tmux-control-buffer-session))))

(defun roost--watched-task ()
  "The task whose agent's terminal or panel is in the selected window, if any.
A panel counts: the terminal is on screen beside it, or it shows the
agent's latest reply.  Only while Emacs has focus, since otherwise
nobody is looking."
  (when (frame-focus-state)
    (with-current-buffer (window-buffer (selected-window))
      (cond ((derived-mode-p 'roost-task-info-mode)
             (and roost--buffer-task-key (gethash roost--buffer-task-key roost--tasks)))
            ((and (fboundp 'tmux-control-active-pane) (tmux-control-active-pane))
             (seq-find (lambda (task) (roost--terminal-shows-p task (list (roost--field task 'paneId))))
                       (roost-tasks)))))))

(defun roost--note-watched-agent ()
  "Mark seen the agent whose terminal is in the selected window."
  (when-let* ((task (roost--watched-task)))
    (roost--mark-seen task)))

(defun roost--status-rank (status)
  "Sort rank of STATUS, an attention status, by how much it needs attention."
  (or (seq-position roost--status-order status) 99))

(defun roost--attention-rank (task)
  "Sort rank of TASK by how much it needs attention."
  (roost--status-rank (roost--attention-status task)))

(defun roost--read-task (prompt)
  "Choose a cached task with PROMPT, those needing attention first."
  (let* ((tasks (sort (roost-tasks)
                      (lambda (a b) (< (roost--attention-rank a) (roost--attention-rank b)))))
         (labels (mapcar (lambda (task)
                           (format "%s  %s · %s" (roost--field task 'name)
                                   (roost--host-label (roost--field task 'host))
                                   (roost--project-name task)))
                         tasks))
         (choices
          (cl-mapcar (lambda (label task)
                       ;; Identical names in one project are told apart by ID.
                       (cons (if (> (seq-count (apply-partially #'equal label) labels) 1)
                                 (format "%s  [%s]" label (substring (roost--field task 'id) 0 6))
                               label)
                             task))
                     labels tasks))
         (annotate
          (lambda (label)
            (let* ((task (cdr (assoc label choices)))
                   (status (roost--row-word task)))
              (concat "  " (propertize status 'face (roost--status-word-face (roost--attention-status task)))
                      (propertize (concat "  " (truncate-string-to-width
                                                (roost--one-line (roost--field task 'task)) 60 nil nil "…"))
                                  'face 'roost-dim))))))
    (unless tasks
      (user-error "No tasks yet; create one with `roost-new-task'"))
    (if (and (mouse-event-p last-nonmenu-event) (display-popup-menus-p))
        ;; A click, as on the mode line's workspace, shows a menu at the
        ;; pointer, as `roost--choose-from' does: a question in the
        ;; minibuffer, which a completion popup hides once you click
        ;; elsewhere, would hold back every task opened after.
        (or (x-popup-menu last-nonmenu-event (list prompt (cons "" choices)))
            (keyboard-quit))
      (cdr (assoc (completing-read
                   prompt
                   (lambda (string predicate action)
                     (if (eq action 'metadata)
                         `(metadata (category . roost-task)
                                    (annotation-function . ,annotate)
                                    (display-sort-function . identity))
                       (complete-with-action action choices string predicate)))
                   nil t)
                  choices)))))

;; String comparisons avoid opening a remote connection just to infer context.
(defun roost--task-in-directory (directory &optional tasks)
  "The task, among TASKS or all, whose worktree contains DIRECTORY."
  (condition-case nil
      (let* ((directory (file-name-as-directory (expand-file-name directory)))
             (host (roost--directory-host directory))
             (local (file-local-name directory)))
        (seq-find (lambda (task)
                    (and (equal host (roost--field task 'host))
                         (string-prefix-p
                          (file-name-as-directory (roost--field task 'worktree))
                          local)))
                  (or tasks (roost-tasks))))
    (user-error nil)))

(defun roost--worktree-file (path &optional directory)
  "PATH in a worktree as a file name, under DIRECTORY or `default-directory'.
A folder there can be named ~, which isn't your home."
  (expand-file-name (concat "./" path) directory))

(defun roost--worktree-relative (task file)
  "FILE's path relative to TASK's worktree, or nil if FILE is elsewhere."
  (when-let* ((task (roost--task-in-directory file (list task))))
    (file-relative-name (file-local-name file)
                        (file-name-as-directory (roost--field task 'worktree)))))

(defun roost--task-at-point ()
  "Task selected in the dashboard, terminal, linked Org entry, or workspace."
  (cond
   ;; A search result of a live task is marked like a dashboard row, and
   ;; so is an attempt among those compared.
   ((derived-mode-p 'roost-dashboard-mode 'roost-search-mode 'roost-attempts-mode)
    (roost--dashboard-task))
   (roost--buffer-task-key
    (or (gethash roost--buffer-task-key roost--tasks)
        (user-error "This task has been retired or is unavailable")))
   (t
    (let ((tasks (roost-tasks))
          (workspace (roost--workspace-backend)))
      (or
       (when-let* ((id (ignore-errors (roost--org-linked-id))))
         (seq-find (lambda (task) (equal (roost--field task 'id) id)) tasks))
       (when (and (fboundp 'tmux-control-active-pane) (tmux-control-active-pane))
         (seq-find (lambda (task)
                     (roost--terminal-shows-p task (list (roost--field task 'paneId)
                                                         (roost--field task 'shellPaneId))))
                   tasks))
       (roost--task-in-directory default-directory tasks)
       (and workspace (roost--workspace-task (roost--current-workspace) tasks))
       ;; An unrelated workspace or file must not silently target the last task.
       (and (not workspace) (not buffer-file-name)
            (gethash roost--current-task roost--tasks)))))))

(defun roost--choose (&optional task)
  "Choose TASK or infer it from context."
  (or task (roost--task-at-point) (roost--read-task "Task: ")))

;;;; Perspectives

(defun roost--perspective-name (task &optional new)
  "Unique workspace name for TASK.
That is the name of its perspective, which may be named for what TASK
was called before a rename: as this Emacs saw it renamed, or else found
by its host and ID.  With NEW, or when it has none, the name for one
made now."
  (let* ((host (roost--host-label (roost--field task 'host)))
         (id (substring (roost--field task 'id) 0 6))
         (name (format "roost:%s:%s:%s" host (roost--field task 'name) id))
         (names (and (not new) (bound-and-true-p persp-mode) (fboundp 'persp-names) (persp-names)))
         (kept (and names (seq-find (lambda (kept) (member kept names))
                                    (gethash (roost--key task) roost--perspectives)))))
    (or (and kept (not (member name names)) kept)
        (and names (not (member name names))
             ;; As restored after Emacs restarted.  The name holds the
             ;; ID's first characters only: none
             ;; another task's ID starts with, or its perspective could be
             ;; the one found.
             (not (seq-some (lambda (other)
                              (and (equal (roost--field other 'host) (roost--field task 'host))
                                   (not (equal (roost--field other 'id) (roost--field task 'id)))
                                   (string-prefix-p id (roost--field other 'id))))
                            (roost-tasks)))
             (seq-find (lambda (other)
                         (and (string-prefix-p (format "roost:%s:" host) other)
                              (string-suffix-p (concat ":" id) other)))
                       names))
        name)))

(defvar roost--workspace-mode-line-map
  (let ((map (make-sparse-keymap)))
    ;; Start minibuffer interaction on release; a subsequent mouse-up can
    ;; otherwise reselect the terminal underneath an active task picker.
    (dolist (area '(mode-line header-line))
      (define-key map (vector area 'down-mouse-1) #'ignore)
      (define-key map (vector area 'mouse-1) #'roost-switch-task))
    map))

(defun roost--workspace-mode-line-label (names current)
  "Compact label for Roost perspective NAMES with CURRENT selected."
  (let* ((active (member current names))
         (task (and active
                    (seq-find (lambda (task) (equal current (roost--perspective-name task)))
                              (roost-tasks))))
         (description
          (when active
            (if task
                (format "%s/%s" (roost--host-label (roost--field task 'host))
                        (roost--field task 'name))
              ;; Restored perspectives can precede the first host refresh.
              (replace-regexp-in-string ":[a-f0-9]\\{6\\}\\'" ""
                                        (string-remove-prefix "roost:" current)))))
         (count (length names)))
    (propertize (if active
                    (concat "Roost: " (truncate-string-to-width description 30 nil nil "…")
                            (if (> count 1) (format " +%d" (1- count)) ""))
                  (format "Roost (%d)" count))
                'face (when active 'persp-selected-face)
                'local-map roost--workspace-mode-line-map
                'mouse-face 'mode-line-highlight
                'help-echo (format "%s%d task workspaces. Click to switch tasks; roost-dashboard shows the dashboard."
                                   (if description (concat description ". ") "")
                                   count))))

(defun roost--compact-perspective-mode-line (original)
  "Collapse task perspectives in ORIGINAL without changing their identity."
  (if (not (and original roost-compact-mode-line
                (bound-and-true-p persp-mode)))
      original
    (let* ((current (persp-current-name))
           (names (persp-names))
           (tasks (seq-filter (lambda (name) (string-prefix-p "roost:" name)) names))
           (visible (if persp-modestring-short (list current) names)))
      (if (not (seq-intersection tasks visible))
          original
        (let (labels grouped)
          (dolist (name visible)
            (if (member name tasks)
                (unless grouped
                  (push (roost--workspace-mode-line-label tasks current) labels)
                  (setq grouped t))
              (push (persp-format-name name) labels)))
          (append (list (nth 0 persp-modestring-dividers))
                  (cdr (apply #'append
                              (mapcar (lambda (label)
                                        (list (nth 2 persp-modestring-dividers) label))
                                      (nreverse labels))))
                  (list (nth 1 persp-modestring-dividers))))))))

(unless (advice-member-p #'roost--compact-perspective-mode-line 'persp-mode-line)
  (advice-add 'persp-mode-line :filter-return #'roost--compact-perspective-mode-line))

(defun roost--workspace-backend ()
  "The workspace mechanism in use: `perspective', `tab-bar' or nil."
  (let ((perspective (and (bound-and-true-p persp-mode)
                          (fboundp 'persp-current-name))))
    (pcase roost-workspace
      ('auto (cond (perspective 'perspective)
                   ((bound-and-true-p tab-bar-mode) 'tab-bar)))
      ('perspective (and perspective 'perspective))
      ('tab-bar 'tab-bar))))

(defun roost--started-before (a b)
  "Whether task A started before task B; their IDs order tasks started at once."
  (let ((a-started (or (roost--field a 'startedAt) ""))
        (b-started (or (roost--field b 'startedAt) "")))
    (if (equal a-started b-started)
        (string< (roost--field a 'id) (roost--field b 'id))
      (string< a-started b-started))))

(defun roost--namesakes (task)
  "The other tasks on TASK's host with its name, eldest first."
  (sort (seq-filter (lambda (other)
                      (and (equal (roost--field other 'host) (roost--field task 'host))
                           (equal (roost--field other 'name) (roost--field task 'name))
                           (not (equal (roost--field other 'id) (roost--field task 'id)))))
                    ;; In any order, as they are sorted next.
                    (hash-table-values roost--tasks))
        #'roost--started-before))

(defun roost--tab-name (task &optional with-id)
  "Name for a new tab of TASK's: its host and name.
With WITH-ID, or when a task of the same name started before it, its
ID follows the name."
  (let ((elder (and (not with-id)
                    (seq-find (lambda (other) (roost--started-before other task))
                              (roost--namesakes task)))))
    (format "%s/%s%s" (roost--host-label (roost--field task 'host)) (roost--field task 'name)
            (if (or with-id elder) (concat ":" (substring (roost--field task 'id) 0 6)) ""))))

(defun roost--tabs ()
  "Names of the tab bar's tabs."
  (mapcar (lambda (tab) (alist-get 'name tab)) (funcall tab-bar-tabs-function)))

(defun roost--task-tab (task)
  "The name of TASK's tab, or nil when it has none.
A task keeps the tab it was given, though a task of the same name has
started or gone since."
  (let ((tabs (roost--tabs)))
    (seq-find (lambda (name) (member name tabs))
              (list (roost--tab-name task t) (roost--tab-name task)))))

(defun roost--workspace-name (task)
  "Name of TASK's workspace in the current backend."
  (if (eq (roost--workspace-backend) 'tab-bar)
      (or (roost--task-tab task) (roost--tab-name task))
    (roost--perspective-name task)))

(defun roost--workspace-task (workspace tasks)
  "The task of TASKS whose workspace is named WORKSPACE, or nil."
  (when workspace
    (seq-find (lambda (task)
                ;; Each name ends in the task's name or the start of its
                ;; ID: only a task whose name or ID could be the one needs
                ;; the tabs and namesakes that say which it is named for.
                (and (or (string-suffix-p (or (roost--field task 'name) "") workspace)
                         (string-suffix-p (substring (roost--field task 'id) 0 6) workspace))
                     (equal workspace (roost--workspace-name task))))
              tasks)))

(defun roost--current-workspace ()
  "Name of the current workspace, or nil without a backend."
  (pcase (roost--workspace-backend)
    ('perspective (persp-current-name))
    ('tab-bar (alist-get 'name (assq 'current-tab (funcall tab-bar-tabs-function))))))

(defun roost--activate-workspace (task)
  "Restore TASK's window arrangement, creating its workspace if needed."
  (roost--leave-side-window)
  (pcase (roost--workspace-backend)
    ('perspective
     (when (fboundp 'persp-switch)
       (persp-switch (roost--perspective-name task))
       (roost--rename-perspective task)))
    ('tab-bar
     (if-let* ((name (roost--task-tab task)))
         (tab-bar-select-tab-by-name name)
       (tab-bar-new-tab)
       (tab-bar-rename-tab (roost--tab-name task)))))
  (setq roost--current-task (roost--key task))
  ;; Without workspaces, the frame's task panel follows the last task used.
  (unless (or (roost--workspace-backend)
              (equal (frame-parameter nil 'roost-task) (roost--key task)))
    (roost--set-aside-drafts task))
  (set-frame-parameter nil 'roost-task (roost--key task))
  (roost--leave-side-window))

(defun roost--rename-perspective (task)
  "Name the current perspective, when it is TASK's, for what TASK is called now.
perspective.el renames no other, so one that wasn't current when TASK
was renamed takes the name when TASK is next opened."
  (let ((name (roost--perspective-name task t)))
    (when (and (fboundp 'persp-rename)
               (equal (persp-current-name) (roost--perspective-name task))
               (not (member name (persp-names))))
      (persp-rename name))))

(defun roost--rename-workspace (old new)
  "Name the workspace of task OLD for NEW, the same task renamed.
That is its tab in each frame, or its perspective where that is current."
  (dolist (frame (frame-list))
    (with-selected-frame frame
      (roost--rename-frame-workspace old new))))

(defun roost--rename-frame-workspace (old new)
  "Name the selected frame's workspace of task OLD for NEW, the task renamed."
  (pcase (roost--workspace-backend)
    ('perspective
     ;; Each frame has perspectives of its own, which may still have
     ;; any name the task had.
     (cl-pushnew (roost--perspective-name old) (gethash (roost--key new) roost--perspectives)
                 :test #'equal)
     (roost--rename-perspective new))
    ('tab-bar
     ;; Not a tab of an elder namesake's, which has the plain name.
     (let* ((tab (roost--task-tab old))
            (name (roost--tab-name new))
            (taken (lambda () (member name (remove tab (roost--tabs)))))
            (namesake (car (roost--namesakes new))))
       ;; NEW is now the eldest of its name: the namesake whose tab has
       ;; the plain name finds its tab by its ID from now on, though
       ;; NEW has no tab here.
       (when (and (funcall taken) namesake (not (roost--started-before namesake new))
                  ;; Unless that tab is another's: the namesake has its own.
                  (not (member (roost--tab-name namesake t) (roost--tabs))))
         (tab-bar-rename-tab (roost--tab-name namesake t)
                             (1+ (seq-position (roost--tabs) name))))
       (when tab
         ;; Any other tab of that name is no task's that Roost knows.
         (tab-bar-rename-tab (if (funcall taken) (roost--tab-name new t) name)
                             (1+ (seq-position (roost--tabs) tab))))))))

;;;; Opening tasks

(defun roost--quiet-session-activity (task)
  "Keep TASK's tmux session out of tmux-control's activity corner.
The corner names other sessions that printed anything, an agent at work
included; Roost already says when an agent needs you, and its commands
switch to the task, not only its terminal.  tmux-control flags a session
from the buffer holding its connection, so that is where this is set."
  (dolist (buffer (buffer-list))
    (when (and (get-buffer-process buffer)
               (fboundp 'tmux-control-buffer-session)
               (with-current-buffer buffer
                 (and (equal (tmux-control-buffer-session) (roost--field task 'session))
                      (equal (tmux-control-buffer-host) (roost--field task 'host))
                      (equal (tmux-control-buffer-socket-name) (roost--field task 'socket)))))
      (with-current-buffer buffer
        (setq-local tmux-control-session-activity nil)))))

(defun roost--switch-session (host socket session)
  "Open the task whose own tmux session is SESSION on HOST and SOCKET.
For `tmux-control-switch-session-functions': switching to a task's
session from a terminal opens the task, in its workspace and beside its
panel, rather than inside the workspace of the task you were in."
  (let ((tasks (seq-filter (lambda (task)
                             (and (equal (roost--field task 'host) host)
                                  (equal (roost--field task 'socket) socket)
                                  (equal (roost--field task 'session) session)))
                           (roost-tasks))))
    ;; A session shared by tasks from before each had its own is no one's.
    (when (and tasks (null (cdr tasks)))
      (roost-open-task (car tasks))
      t)))

(defun roost--keep-terminal-in-its-workspace ()
  "Keep the current buffer, a terminal, out of other tasks' workspaces.
For `after-change-major-mode-hook': a terminal reconnecting in the
background joins whichever perspective is current, so the buffer list
of one task would offer the terminals of the others.  The terminal's
mode comes before it knows its session, and it joins the perspective
when it is shown, later still: this looks once the reconnect is done."
  (when (and (derived-mode-p 'tmux-control-mode)
             (eq (roost--workspace-backend) 'perspective))
    (run-at-time 0 nil #'roost--forget-terminal-elsewhere (current-buffer))))

(defun roost--forget-terminal-elsewhere (buffer)
  "Take BUFFER, a task's terminal, out of perspectives not its task's.
That is the current perspective of each frame, where it lists BUFFER
without showing it: one you show it in is yours."
  (when-let* (((buffer-live-p buffer))
              ((fboundp 'persp-forget-buffer))
              ((eq (roost--workspace-backend) 'perspective))
              (task (roost--terminal-task buffer)))
    ;; Each frame has perspectives of its own, and the task's may have
    ;; another name in each.
    (dolist (frame (frame-list))
      (unless (frame-parent frame)
        (with-selected-frame frame
          (when (and (persp-is-current-buffer buffer)
                     (not (get-buffer-window buffer))
                     (not (equal (persp-current-name) (roost--perspective-name task))))
            ;; Not `persp-remove-buffer', which kills a buffer no other
            ;; perspective has.  This one makes the selected window's
            ;; buffer current, until `with-selected-frame' puts it back.
            (persp-forget-buffer buffer)))))))

(defun roost--gather-task-terminals (&optional buffer)
  "Add the terminals of the current perspective's task to it.
For `persp-switch-hook', and with BUFFER for
`tmux-control-window-buffer-functions'.  perspective.el adds a buffer
when it is shown, but tmux-control makes a buffer for a tmux window
you haven't visited without showing it, when
`tmux-control-window-buffers' is `all'.  BUFFER goes in its task's
perspective now in each frame where that is current, and otherwise
when it becomes so."
  (if buffer
      ;; Each frame has perspectives of its own, and the task's may be
      ;; current in one you aren't in.
      (dolist (frame (frame-list))
        (unless (frame-parent frame)
          (with-selected-frame frame
            (roost--gather-frame-terminals (list buffer)))))
    (roost--gather-frame-terminals (buffer-list))))

(defun roost--gather-frame-terminals (buffers)
  "Add those of BUFFERS that are terminals of the current perspective's task to it.
That is the selected frame's current perspective."
  ;; Look the task up once, not each buffer's.
  (when-let* ((tasks (and (eq (roost--workspace-backend) 'perspective)
                          (fboundp 'persp-add-buffer)
                          (roost-tasks)))
              (task (roost--workspace-task (roost--current-workspace) tasks))
              (session (roost--field task 'session)))
    ;; A session shared by tasks from before each had its own is no one's.
    (unless (seq-find (lambda (other)
                        (and (not (eq other task))
                             (equal (roost--field other 'host) (roost--field task 'host))
                             (equal (roost--field other 'socket) (roost--field task 'socket))
                             (equal (roost--field other 'session) session)))
                      tasks)
      (dolist (buffer buffers)
        (when (and (buffer-live-p buffer)
                   (provided-mode-derived-p (buffer-local-value 'major-mode buffer) 'tmux-control-mode)
                   (with-current-buffer buffer
                     (and (equal (tmux-control-buffer-session) session)
                          (equal (tmux-control-buffer-host) (roost--field task 'host))
                          (equal (tmux-control-buffer-socket-name) (roost--field task 'socket)))))
          (persp-add-buffer buffer))))))

(defun roost--task-terminal-window (task)
  "The window of the selected frame showing TASK's terminal, or nil."
  (when (and task (fboundp 'tmux-control-window-id))
    (seq-find (lambda (window)
                (with-current-buffer (window-buffer window)
                  (and (tmux-control-window-id)
                       (not (tmux-control-tiled-p))
                       (equal (tmux-control-buffer-host) (roost--field task 'host))
                       (equal (tmux-control-buffer-socket-name) (roost--field task 'socket))
                       (equal (tmux-control-buffer-session) (roost--field task 'session))
                       (equal (tmux-control-window-id) (roost--field task 'windowId)))))
              (window-list))))

(defun roost--terminal-task (buffer)
  "The task whose terminal BUFFER is, or nil.
A session shared by tasks from before each had its own is no one's, and
a view of a terminal, such as its scrollback, is no terminal."
  (with-current-buffer buffer
    (when (and (derived-mode-p 'tmux-control-mode)
               (fboundp 'tmux-control-buffer-session) (tmux-control-buffer-session))
      (let ((tasks (seq-filter (lambda (task)
                                 (and (equal (roost--field task 'host) (tmux-control-buffer-host))
                                      (equal (roost--field task 'socket) (tmux-control-buffer-socket-name))
                                      (equal (roost--field task 'session) (tmux-control-buffer-session))))
                               (roost-tasks))))
        (and tasks (null (cdr tasks)) (car tasks))))))

(defun roost--terminal-place (buffer)
  "The host, socket and tmux session of terminal BUFFER, or nil.
Nil for a view of a terminal, such as its scrollback, too."
  (when (and (buffer-live-p buffer) (fboundp 'tmux-control-buffer-session))
    (with-current-buffer buffer
      (when-let* (((derived-mode-p 'tmux-control-mode))
                  (session (tmux-control-buffer-session)))
        (list (tmux-control-buffer-host) (tmux-control-buffer-socket-name) session)))))

(defun roost--still-there-p (window shown place frame)
  "Whether you are still where you were: in WINDOW, which showed SHOWN.
Or in the same terminal in FRAME, WINDOW's, at PLACE as
`roost--terminal-place' said of SHOWN then, which tmux-control shows
another way meanwhile: as it tiles a split terminal again, when the
minibuffer gives back the lines it took, a window can show another
pane's buffer, or another window the one you were in."
  (or (and (eq (selected-window) window) (eq (window-buffer window) shown))
      (and place (eq (selected-frame) frame)
           (equal (roost--terminal-place (window-buffer (selected-window))) place))))

(defun roost--window-you-are-in ()
  "The selected window, or the one you asked a question from in the minibuffer."
  (or (and (window-minibuffer-p) (minibuffer-selected-window))
      (selected-window)))

(defun roost--you-stay ()
  "Return a function that says whether you are still where you are now.
That is, whether you have opened nothing since, and are in the same
window and buffer, or a minibuffer you asked from there.  For a command
that opens something once its host replies: a reply that takes more than
a moment, as an agent's start does, must not take you from where you went."
  (let* ((generation (cl-incf roost--open-generation))
         (window (roost--window-you-are-in))
         (shown (window-buffer window))
         (place (roost--terminal-place shown))
         (frame (window-frame window)))
    (lambda ()
      (and (= generation roost--open-generation)
           (with-selected-window (roost--window-you-are-in)
             (roost--still-there-p window shown place frame))))))

(defun roost--while-you-stay (task)
  "Return a function for a command that opens something of TASK's.
It takes a function that opens it, and calls that once you are out of
the minibuffer, unless by then you have gone elsewhere, as
`roost--you-stay' says, or TASK went."
  (let* ((stayed (roost--you-stay))
         (key (roost--key task))
         (listed (gethash key roost--tasks)))
    (lambda (open)
      (roost--when-out-of-minibuffer
       (lambda ()
         (when (and (funcall stayed) (not (roost--went-p key listed)))
           (funcall open)))))))

(defun roost--terminal-window-for (task)
  "The window to show TASK's terminal in, or nil for the selected one.
That is the window showing it already, or else one showing another
task's terminal, the one used last: TASK takes its place, rather than
that of a code or Magit window selected beside it, which would leave
the other task's terminal on screen.  TASK's own panes, when tiled, are
not another task's: they keep their grid."
  (or (roost--task-terminal-window task)
      (seq-find (lambda (window)
                  (when-let* ((shown (roost--terminal-task (window-buffer window))))
                    (not (equal (roost--key shown) (roost--key task)))))
                (sort (roost--main-windows)
                      (lambda (a b) (> (window-use-time a) (window-use-time b)))))))

(defun roost--display-task (task &optional target-pane)
  "Display TASK after ownership validation, selecting TARGET-PANE if supplied."
  (require 'tmux-control)
  (add-hook 'tmux-control-switch-session-functions #'roost--switch-session)
  (add-hook 'after-change-major-mode-hook #'roost--keep-terminal-in-its-workspace 90)
  (add-hook 'tmux-control-window-buffer-functions #'roost--gather-task-terminals)
  (add-hook 'persp-switch-hook #'roost--gather-task-terminals)
  (roost--leave-side-window)
  (roost--activate-workspace task)
  (roost--leave-side-window)
  (when-let* ((window (roost--terminal-window-for task)))
    (select-window window))
  (tmux-control-connect-or-switch (roost--field task 'host) (roost--field task 'socket)
                                  (roost--field task 'session))
  (roost--quiet-session-activity task)
  ;; Explicit window hop also works before the pane map arrives on connect.
  (let ((window (roost--field task 'windowId))
        (pane (or target-pane (roost--field task 'paneId))))
    (unless (and (stringp window) (string-match-p "\\`@[0-9]+\\'" window)
                 (stringp pane) (string-match-p "\\`%[0-9]+\\'" pane))
      (user-error "Invalid tmux target"))
    (with-current-buffer (window-buffer (selected-window))
      (tmux-control-send-command (format "select-window -t %s" window))
      (tmux-control-select-pane pane)))
  (roost--mark-seen (or (gethash (roost--key task) roost--tasks) task))
  (unless (roost--workspace-backend)
    (roost--bring-back-drafts task))
  (roost--watch-layout)
  (roost--sync-side-windows)
  (roost--mark-in-sidebar)
  (when (roost--task-panel-window)
    (roost--refresh-host (roost--field task 'host) nil)))

(defun roost--mark-in-sidebar ()
  "Draw the sidebar again, so that it marks the task opened now.
Rather than once its host replies."
  (when-let* ((sidebar (get-buffer roost--sidebar-buffer)))
    (with-current-buffer sidebar
      (when (derived-mode-p 'roost-sidebar-list-mode)
        (roost--render-visible #'roost--render-sidebar)))))

(defun roost--other-terminal-window (task)
  "A window of the selected frame showing another task's terminal, or nil.
Nil, too, when the frame shows TASK's own terminal."
  (unless (roost--task-terminal-window task)
    (roost--terminal-window-for task)))

(defun roost--in-task-frame (task view)
  "Call VIEW to show something of TASK's, such as Magit, in TASK's frame.
A frame shows one task: with workspaces, VIEW shows in TASK's.  Where
another task's terminal is on screen, TASK's terminal takes its place
first, as \\[roost-open-task] does, and VIEW shows beside it once TASK's
host replies.  A task without a terminal, as once stopped, takes the
frame without one: see `roost--take-frame'."
  (when (roost--workspace-backend)
    ;; Whose terminal its workspace shows: a new tab shows the one you
    ;; were in.
    (roost--activate-workspace task))
  (if (and (roost--other-terminal-window task)
           (roost--field task 'windowId)
           (not (gethash (roost--field task 'host) roost--errors)))
      (progn
        ;; TASK's workspace is TASK's already: the other task's terminal
        ;; goes now, rather than stay there if you go elsewhere before
        ;; the host replies.  Without workspaces, the frame is the other
        ;; task's until then.
        (when (roost--workspace-backend)
          (roost--put-away-other-terminals task))
        (roost--open task view))
    (roost--take-frame task)
    (funcall view)))

(defun roost--put-away-other-terminals (task)
  "Put away the terminals of tasks other than TASK in the selected frame.
Each window goes back to what it showed before, never to another task's
terminal or a draft."
  (let ((switch-to-prev-buffer-skip
         (lambda (_window buffer _bury-or-kill)
           (or (roost--terminal-task buffer) (roost--draft-task buffer)))))
    (dolist (window (roost--main-windows))
      (when-let* ((shown (roost--terminal-task (window-buffer window))))
        (unless (or (equal (roost--key shown) (roost--key task))
                    (switch-to-prev-buffer window))
          (set-window-buffer window (get-scratch-buffer-create)))))))

(defun roost--take-frame (task)
  "Make the selected frame TASK's, as for a view of it, without its terminal.
Another task's terminal there goes back to what its window showed
before, but not to another task's terminal.  TASK's drafts another task
took off the frame come back, as when TASK is opened."
  (roost--put-away-other-terminals task)
  (roost--activate-workspace task)
  (unless (roost--workspace-backend)
    (roost--bring-back-drafts task))
  (roost--mark-in-sidebar))

(defvar-local roost--set-aside nil
  "The frames this draft was taken off when other tasks took them.
A draft can show in more than one frame, and comes back in each.")

(defun roost--draft-task (buffer)
  "The task BUFFER is a prompt or pull request draft for, or nil."
  (or (buffer-local-value 'roost--send-task buffer)
      (buffer-local-value 'roost--pr-task buffer)))

(defun roost--set-aside-drafts (task)
  "Take the drafts for tasks other than TASK off the selected frame.
For when TASK takes the frame: without workspaces a frame shows one
task.  A prompt or pull request draft for another task stays as it is,
unseen, until that task is opened in the frame again: see
`roost--bring-back-drafts'.  Its window closes, or, as the frame's last,
shows what it did before, though not another task's terminal or draft."
  (let ((switch-to-prev-buffer-skip
         (lambda (_window buffer _bury-or-kill)
           (or (roost--terminal-task buffer) (roost--draft-task buffer)))))
    (dolist (window (roost--main-windows))
      (let* ((buffer (window-buffer window))
             (other (roost--draft-task buffer)))
        (when (and other (not (equal (roost--key other) (roost--key task))))
          (with-current-buffer buffer
            (setq roost--set-aside (cons (selected-frame)
                                         (seq-filter #'frame-live-p
                                                     (remq (selected-frame) roost--set-aside)))))
          (if (eq (window-deletable-p window) t)
              (delete-window window)
            (switch-to-prev-buffer window)))))))

(defun roost--bring-back-drafts (task)
  "Show TASK's drafts again that another task took off the selected frame.
Beside its terminal, which stays selected."
  (dolist (buffer (buffer-list))
    (when (memq (selected-frame) (buffer-local-value 'roost--set-aside buffer))
      (when-let* ((own (roost--draft-task buffer))
                  ((equal (roost--key own) (roost--key task))))
        ;; Only this frame's: another may wait for it too.
        (with-current-buffer buffer
          (setq roost--set-aside (remq (selected-frame) roost--set-aside)))
        (unless (get-buffer-window buffer)
          (display-buffer buffer '(nil (inhibit-same-window . t))))))))

(defvar roost--held-for-minibuffer 0
  "How many things Roost holds back until the minibuffer is done.
Such as a task to show, by `roost--when-out-of-minibuffer'.")

(defun roost--when-out-of-minibuffer (function)
  "Call FUNCTION now, or once the minibuffer you are in is done.
A task is shown when its host replies, which can be while you answer a
question that came up since; changing windows then would send your
answer to the task's terminal.  A question you had left open when you
asked for the task is quit first, by `roost--quit-questions-left-open'."
  (if (not (active-minibuffer-window))
      (funcall function)
    (cl-incf roost--held-for-minibuffer)
    (letrec ((done (lambda ()
                     (cl-decf roost--held-for-minibuffer)
                     (remove-hook 'minibuffer-exit-hook done)
                     ;; Once its window has given the selection back.
                     (run-at-time 0 nil #'roost--when-out-of-minibuffer function))))
      ;; In turn: a terminal that goes, then the one that takes its place.
      (add-hook 'minibuffer-exit-hook done t))))

(defun roost--close-buffer (buffer)
  "Close BUFFER, as a host's reply says it is done, and the windows made for it.
You stay where you are: on Emacs 30, quitting a window selects the one
you were in as it came to show BUFFER, from wherever you have gone
since, out of the minibuffer too.  Done once you are out of the
minibuffer, which there fails as it ends if the buffer you asked from
is gone."
  (roost--when-out-of-minibuffer
   (lambda ()
     (when (buffer-live-p buffer)
       (let ((selected (selected-window)))
         ;; Before Emacs 31 this kills only a buffer that shows.
         (quit-windows-on buffer t)
         (when (buffer-live-p buffer) (kill-buffer buffer))
         (when (and (window-live-p selected) (not (eq selected (selected-window))))
           (select-window selected)))))))

(defun roost--open-once-out (generation key listed open)
  "Call OPEN once you are out of the minibuffer, if it is still wanted.
Not if you opened something since GENERATION, as what you chose there,
or the task with KEY went, LISTED being as for `roost--went-p'."
  (roost--when-out-of-minibuffer
   (lambda ()
     (when (and (= generation roost--open-generation)
                (not (roost--went-p key listed)))
       (funcall open)))))

(defun roost--stayed-as-it-goes (stayed note)
  "Call NOTE with what STAYED says, now and once out of the minibuffer.
That is whether you stay, for a task that resumes, as its host replies:
its terminal, which you may be in, is about to go, and what you chose in
the minibuffer, as a file, shows by then.  So this goes first: asked
after the terminal has gone, where you are says nothing."
  (funcall note (funcall stayed))
  (roost--when-out-of-minibuffer (lambda () (funcall note (funcall stayed)))))

(defun roost--ask-after-reply (key listed function)
  "Call FUNCTION, which asks about the task with KEY, once out of a host's reply.
That is from a timer, and once the minibuffer you are in is done, as a
reply can come while you write there: a question asked from it lands in
that minibuffer, and the next key you press answers it.  Not if the task
went by then, LISTED being as for `roost--went-p'.  A `user-error' from
FUNCTION is said as a command's is."
  (run-at-time 0 nil #'roost--when-out-of-minibuffer
               (lambda ()
                 (unless (roost--went-p key listed)
                   (condition-case err
                       (funcall function)
                     (user-error (message "%s" (error-message-string err))))))))

(defun roost--questions-left-open ()
  "How many questions you left open in the minibuffer, by going to another window.
A completion popup, such as vertico-posframe's, hides a question you
leave, and \\[keyboard-quit] there leaves it open.  Nil when you are in
the minibuffer, or when a recursive edit of another kind, such as the
debugger's, is open as well."
  (and (active-minibuffer-window)
       (not (minibufferp (window-buffer (selected-window)) t))
       (= (recursion-depth) (minibuffer-depth))
       (minibuffer-depth)))

(defun roost--quit-questions-left-open (then)
  "Quit the questions you left open in the minibuffer, then call THEN.
Return nil, without calling THEN, when there are none.  Otherwise this
doesn't return: quitting a question gives back the windows it found,
which would undo what THEN shows, so THEN runs after, unless you have
opened another task meanwhile.  Only for a command you gave, never from
a host's reply, which can arrive while another command waits: the
quitting would end that command too."
  (when-let* ((count (roost--questions-left-open)))
    (let ((questions (if (> count 1)
                         (format "%d questions" count)
                       (format "\"%s\"" (truncate-string-to-width
                                         (string-trim (or (minibuffer-prompt) "")) 50 nil nil "…"))))
          (generation (cl-incf roost--open-generation)))
      (run-at-time 0 nil (lambda ()
                           (message "Quit %s left open in the minibuffer" questions)
                           (when (= generation roost--open-generation)
                             (funcall then))))
      (minibuffer-quit-recursive-edit count))))

(defconst roost--opening-delay 0.5
  "Seconds a task's host can take to reply before Roost says it is opening.")

(defvar roost--opening-timer nil
  "The timer that says the task you opened last is opening.")

;;;###autoload
(defun roost-open-task (&optional task quit-questions describe)
  "Validate TASK's tmux ownership, then restore its perspective and terminal.
With QUIT-QUESTIONS, as when you give a command, first quit the
questions you left open in the minibuffer, which would hold the task
back, unseen, until you answered them.  DESCRIBE is as for `roost--open'."
  (interactive (list nil t))
  (when (and quit-questions (roost--questions-left-open))
    ;; The task at point is where you are now, before quitting gives
    ;; back the windows; asking which comes after, as the question left
    ;; open can keep another from being asked.
    (let ((task (or task (roost--task-at-point))))
      (roost--quit-questions-left-open
       (lambda () (roost-open-task (or task (roost--read-task "Task: ")) nil describe)))))
  (roost--open (roost--choose task) nil describe))

(defun roost--open (task &optional view describe)
  "Show TASK's terminal, once its host confirms that Roost owns it.
VIEW, if given, then shows something of TASK's beside it, such as
Magit: for a task whose agent's window is gone, VIEW shows without the
terminal, rather than Roost asking to resume the task.  DESCRIBE, if
given, is called with TASK as its host replied, before it shows, as
seeing it changes what it waits for; what it returns, the echo area
says once the terminal shows."
  ;; From a child frame, such as the box a review note is written in, in
  ;; the frame it floats over: a terminal shown in the child frame's place
  ;; would leave that frame naming the task it showed before.
  (when (frame-parent)
    (let ((frame (selected-frame)))
      (while (frame-parent frame)
        (setq frame (frame-parent frame)))
      (select-frame-set-input-focus frame)))
  (let* ((generation (cl-incf roost--open-generation))
         (window (if (window-minibuffer-p) (minibuffer-selected-window) (selected-window)))
         (shown (window-buffer window))
         (place (roost--terminal-place shown))
         (frame (window-frame window))
         (name (roost--field task 'name))
         (key (roost--key task))
         (listed (gethash key roost--tasks))
         (opening (format "Roost: opening %s…" name))
         ;; A host slow to reply, as over SSH, looked like a click that
         ;; did nothing.
         (timer (progn
                  (when (timerp roost--opening-timer) (cancel-timer roost--opening-timer))
                  (setq roost--opening-timer
                        (run-at-time roost--opening-delay nil
                                     (lambda ()
                                       (when (= generation roost--open-generation)
                                         (message "%s" opening)))))))
         ;; Unless you have opened another task since, or shown something
         ;; else, such as tmux-control's pager, or the task went.
         (still-wanted (lambda ()
                         (and (= generation roost--open-generation)
                              (not (when (roost--went-p key listed)
                                     (message "Roost: didn't open %s, as it is no longer listed" name)
                                     t))
                              (or (roost--still-there-p window shown place frame)
                                  (progn
                                    (message "Roost: didn't open %s, as you went to another window or buffer while its host replied"
                                             name)
                                    nil))))))
    (roost--request (roost--field task 'host) "inspect"
                    (list (cons 'id (roost--field task 'id)))
                    (lambda (current)
                      (cancel-timer timer)
                      (setq current (roost--cache-reply (roost--field task 'host) current listed))
                      ;; The reply can be newer than what is shown, as when
                      ;; you answered the agent meanwhile: show it everywhere,
                      ;; the task's panel too, not only where the task opens.
                      (roost--redraw)
                      (let ((held (active-minibuffer-window)))
                        (roost--when-out-of-minibuffer
                         (lambda ()
                           (when (funcall still-wanted)
                             (if held
                                 ;; You can take your time there, and connecting
                                 ;; to a session that ended starts an empty one.
                                 (roost--open task view describe)
                               (when (equal (current-message) opening)
                                 (message nil))
                               (let ((said (and describe (funcall describe current))))
                                 (roost--display-task current)
                                 (cond (view (funcall view))
                                       (said (message "%s" said))
                                       ((and (assq 'live current) (not (roost--field current 'live)))
                                        (message "%s's agent has %s; its last output is shown. Resume with `s'."
                                                 (roost--field current 'name)
                                                 (roost--field current 'status)))))))))))
                    (lambda (err)
                      (cancel-timer timer)
                      ;; Stopped, or its tmux server gone, as after a crash:
                      ;; resuming is the way to its terminal.  Asked once
                      ;; any question you are answering is done, too.
                      (roost--when-out-of-minibuffer
                       (lambda ()
                         (cond
                          ((not view)
                           (if (and (= generation roost--open-generation)
                                    (string-prefix-p "The agent's tmux window is gone" err))
                               ;; Asked from a timer, not from this reply's
                               ;; sentinel, and only if you haven't moved on
                               ;; or started a question since: a prompt nobody
                               ;; saw held every later switch behind it.
                               (run-at-time
                                0 nil #'roost--when-out-of-minibuffer
                                (lambda ()
                                  ;; Nor about a task that went, whose window
                                  ;; is gone for good.
                                  (when (and (= generation roost--open-generation)
                                             (not (roost--went-p key listed)))
                                    (let* ((current (or (gethash key roost--tasks) task))
                                           ;; As after its host restarted: one
                                           ;; question for all of them.
                                           (others (roost--crashed-with current))
                                           (name (roost--field task 'name))
                                           (host (roost--host-label (roost--field task 'host))))
                                      ;; You know now; `n' moves on to the next.
                                      (roost--mark-seen current)
                                      (when (y-or-n-p
                                             (cond ((null others)
                                                    (format "%s's agent isn't running.  Resume its conversation? "
                                                            name))
                                                   ((cdr others)
                                                    (format "%s's agent isn't running, nor %d others' on %s.  Resume all %d? "
                                                            name (length others) host (1+ (length others))))
                                                   (t (format "%s's agent isn't running, nor one other's on %s.  Resume both? "
                                                              name host))))
                                        (if others
                                            (roost--resume-together current others)
                                          (roost-resume task)))))))
                             (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err)))
                          ;; A view of the task shows without its terminal.
                          ((funcall still-wanted)
                           (when (equal (current-message) opening)
                             (message nil))
                           (unless (string-prefix-p "The agent's tmux window is gone" err)
                             (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err))
                           (roost--take-frame task)
                           (funcall view)))))))))

;;;###autoload
(defun roost-switch-task ()
  "Choose a task across hosts and restore its workspace."
  (interactive)
  ;; Before asking, which a question left open can keep from happening.
  (roost--quit-questions-left-open
   (lambda () (roost-open-task (roost--read-task "Switch task: "))))
  (roost-open-task (roost--read-task "Switch task: ")))

;;;; Creating tasks

(defun roost--project-directory (task)
  "TASK's primary checkout as a local or TRAMP directory."
  (roost--remote-directory (cons (cons 'worktree (roost--field task 'repo)) task)))

(defun roost--remember-project (directory)
  "Remember project DIRECTORY, most recent first, across restarts."
  (setq directory (file-name-as-directory directory))
  (roost--projects-as-on-file)
  (setq roost--remembered-projects
        (seq-take (cons directory (delete directory roost--remembered-projects)) 50))
  (roost--write-json-list roost-projects-file roost--remembered-projects))

(defun roost--known-projects ()
  "Project checkouts used for tasks, most recent first, without network I/O."
  (unless roost--projects-loaded
    (setq roost--projects-loaded t
          roost--remembered-projects
          (seq-filter #'stringp (roost--read-remembered roost-projects-file))))
  (delete-dups (append roost--remembered-projects
                       ;; A record naming no repository names no project.
                       (mapcar #'roost--project-directory
                               (seq-filter (lambda (task) (roost--field task 'repo)) (roost-tasks))))))

(defun roost--projects-as-on-file ()
  "Take up the projects `roost-projects-file' holds, if another Emacs changed them."
  (roost--known-projects)
  (let ((projects (roost--read-again roost-projects-file)))
    (unless (eq projects 'same)
      (setq roost--remembered-projects (seq-filter #'stringp projects)))))

;;;###autoload
(defun roost-forget-project (directory)
  "Stop offering project DIRECTORY for new tasks.
The sidebar no longer lists it.  Drafts offer it still while one of its
tasks is listed, or project.el knows it, as `project-forget-project'
changes.  Its tasks are left as they are, and starting another task
there remembers it again."
  (interactive
   (progn
     (roost--known-projects)
     (list (or (pcase (get-text-property (point) 'roost-project)
                 ('other (user-error "No project here"))
                 ((and (pred stringp) project) project))
               (let ((projects (mapcar (lambda (project) (cons (roost--project-label project) project))
                                       roost--remembered-projects)))
                 (unless projects (user-error "Roost remembers no projects"))
                 (cdr (assoc (completing-read "Forget project: " projects nil t) projects)))))))
  (roost--projects-as-on-file)
  ;; However it was spelled, as by another TRAMP method, which the
  ;; sidebar takes for the same project.
  (let ((place (roost--project-place directory)))
    (setq roost--remembered-projects
          (seq-remove (lambda (project)
                        (if place
                            (equal (roost--project-place project) place)
                          (equal project (file-name-as-directory directory))))
                      roost--remembered-projects)))
  (roost--write-json-list roost-projects-file roost--remembered-projects)
  (roost--redraw)
  (message "Roost no longer offers %s" (roost--project-label directory)))

(defun roost--project-choices ()
  "Projects to offer for a new task: Roost's own, then those project.el knows.
A local one from project.el must be a Git checkout; a remote one is
offered as it is, since checking it would open a connection."
  (delete-dups
   (append (roost--known-projects)
           (delq nil (mapcar (lambda (root)
                               (if (file-remote-p root)
                                   (file-name-as-directory root)
                                 (let ((root (file-name-as-directory (expand-file-name root))))
                                   (when (file-exists-p (expand-file-name ".git" root)) root))))
                             (when (require 'project nil t)
                               (ignore-errors (project-known-project-roots))))))))

(defun roost--host-projects (host)
  "Paths on HOST of the projects Roost has used there."
  (delq nil (mapcar (lambda (directory)
                      (when (equal (ignore-errors (roost--directory-host directory)) host)
                        (directory-file-name (file-local-name directory))))
                    (roost--known-projects))))

(defun roost--bare-host (host)
  "HOST without its user, as me@dev and dev are one machine; nil for local."
  (and host (replace-regexp-in-string "\\`[^@]*@" "" host)))

(defun roost--project-place (directory)
  "Project DIRECTORY as (HOST . PATH), HOST without its user, or nil.
By name alone, so it opens no connection, and whatever TRAMP method
spells it."
  (when-let* ((at (roost--host-and-path directory)))
    (cons (roost--bare-host (car at)) (cdr at))))

(defun roost--recent-projects (tasks)
  "Projects none of TASKS is in that the sidebar lists, in its order.
On each host Roost watches, the `roost-sidebar-recent-projects' you
used last.  Matched by host and path alone, so none opens a connection."
  (let* ((taken (mapcar (lambda (task)
                          (cons (roost--bare-host (roost--field task 'host))
                                (file-name-as-directory (or (roost--field task 'repo) ""))))
                        tasks))
         (hosts (mapcar #'roost--bare-host (roost--hosts)))
         (counts nil)
         (places nil))
    (roost--known-projects)
    ;; Those of tasks are taken anyway.
    (dolist (directory roost--remembered-projects)
      (when-let* ((place (roost--project-place directory))
                  ((member (car place) hosts))
                  ((not (member place taken)))
                  ((not (assoc place places)))
                  (count (alist-get (car place) counts 0 nil #'equal))
                  ((< count roost-sidebar-recent-projects)))
        (setf (alist-get (car place) counts 0 nil #'equal) (1+ count))
        (push (cons place directory) places)))
    (mapcar #'cdr (sort places (lambda (a b)
                                 (string< (format "%s %s" (roost--host-label (caar a)) (cdar a))
                                          (format "%s %s" (roost--host-label (caar b)) (cdar b))))))))

(defun roost--abbreviate-path (path &optional host)
  "PATH with its owner's home directory shown as ~.
Locally that is your home directory.  On HOST it is /home/USER or
/Users/USER for the USER its name gives, as in me@dev; without one,
PATH is shown in full, as its home isn't known without a connection."
  (let ((home (cond ((not host)
                     (regexp-quote (directory-file-name (expand-file-name "~"))))
                    ((string-match "\\`\\([^@]+\\)@" host)
                     (concat "/\\(?:home\\|Users\\)/" (regexp-quote (match-string 1 host)))))))
    (if home
        (replace-regexp-in-string (concat "\\`" home "\\(/\\|\\'\\)") "~\\1" path)
      path)))

(defun roost--project-label (directory)
  "Short label such as \"claylien · ~/code/app\" for project DIRECTORY."
  (format "%s · %s"
          (roost--host-label (ignore-errors (roost--directory-host directory)))
          (roost--abbreviate-path (directory-file-name (file-local-name directory))
                                  (ignore-errors (roost--directory-host directory)))))

(defun roost--name-from-prompt (prompt)
  "A short task name derived from the first words of PROMPT.
The first line names the task when it has two or more meaningful words,
as a summary or an Org heading does.  Hyphenated words such as
off-by-one stay whole, repeated words are dropped, and the name ends at
a word, within 40 characters."
  (let* ((common '("a" "an" "the" "to" "and" "of" "in" "for" "on" "with" "so" "is" "are"
                   "it" "its" "that" "this" "be" "as" "by" "at" "or" "please" "make" "should"
                   "we" "i" "you" "can" "could" "would"))
         (words-of (lambda (text)
                     (seq-uniq
                      (seq-remove (lambda (word) (or (string-empty-p word) (member word common)))
                                  (mapcar (lambda (word) (string-trim word "-+" "-+"))
                                          (split-string (downcase (replace-regexp-in-string
                                                                   "[^[:alnum:]-]+" " "
                                                                   ;; command's, not command-s
                                                                   (replace-regexp-in-string
                                                                    "['’]" "" (or text ""))))
                                                        " +" t))))))
         (first-line (funcall words-of (car (split-string (or prompt "") "\n" t "[ \t]+"))))
         (words (if (>= (length first-line) 2) first-line (funcall words-of prompt)))
         (name ""))
    (catch 'full
      (dolist (word (seq-take words 4))
        (let ((longer (if (string-empty-p name) word (concat name "-" word))))
          (when (and (> (length longer) 40) (not (string-empty-p name)))
            (throw 'full nil))
          (setq name longer))))
    (truncate-string-to-width name 40)))

(defun roost--agent-command (agent)
  "Executable and arguments for AGENT."
  (or (cdr (assoc agent roost-agent-commands))
      (list agent)))

(defvar roost--project-values nil
  "What `roost--project-value' has read, while a command binds this to (t).
Then a list of t and each ((DIRECTORY . VARIABLE) . VALUE).  A command
that asks a host for several things of one project, as a draft that
makes several attempts, reads each value once, so that Emacs asks about
the project's local variables once.")

(defun roost--project-value (directory variable)
  "VARIABLE's value for the project in DIRECTORY, which may set it locally."
  (if-let* ((read (assoc (cons directory variable) (cdr roost--project-values))))
      (cdr read)
    (let ((value (with-temp-buffer
                   (setq default-directory directory)
                   (hack-dir-local-variables-non-file-buffer)
                   (symbol-value variable))))
      (when roost--project-values
        (push (cons (cons directory variable) value) (cdr roost--project-values)))
      value)))

(defun roost--create-task (directory name base prompt agent &optional on-success on-failure extra)
  "Create an AGENT task NAME in DIRECTORY from BASE with PROMPT.
Call ON-SUCCESS with the task before it opens, or ON-FAILURE with an error.
EXTRA is an alist of further request fields, such as the issue."
  (setq agent (or agent roost-default-agent))
  (unless (member agent roost--agents)
    (user-error "Unsupported Roost agent: %s" agent))
  (let ((host (roost--directory-host directory))
        ;; A conversation is in no project of yours, so none's setup runs.
        (setup (unless (alist-get 'conversation extra)
                 (roost--project-value directory 'roost-setup-command)))
        (stayed (roost--you-stay)))
    (roost--request
     host "create"
     `(,(cons 'directory (file-local-name directory))
           ,(cons 'name name)
           ,(cons 'base base)
           ,(cons 'agent agent)
           ,(cons 'prompt (unless (string-empty-p (string-trim (or prompt ""))) prompt))
           ,(cons 'command (vconcat (roost--agent-command agent)))
           ,(cons 'setup setup)
           ,(cons 'branchPrefix roost-branch-prefix)
           ,(cons 'programStatus (if roost-program-status t :false))
           ,(cons 'mayOffer (if roost-agent-offers t :false))
           ,(cons 'remoteControl (if roost-remote-control t :false))
           ,(cons 'size (roost--terminal-size))
           ,(cons 'socket (or roost-socket-name
                              (bound-and-true-p tmux-control-default-socket-name)
                              "main"))
           . ,extra)
     (lambda (task)
       (cl-incf (gethash host roost--revisions 0))
       (roost--task-made host task name on-success stayed))
     (lambda (err)
       (message "Roost could not create %s: %s" name err)
       (when on-failure (funcall on-failure err)))
     (+ roost-request-timeout roost--create-seconds))
    (message "Roost: creating %s…" name)))

(defun roost--task-made (host task name on-success stayed)
  "Cache TASK, which HOST made as NAME, and call ON-SUCCESS, if any, with it.
ON-SUCCESS also gets whether an earlier request made it, which its host
says.  Then open it, if STAYED, called once you are out of the minibuffer
and before ON-SUCCESS moves anything, says you are still where you asked
for it: making a task can take minutes.  Not if ON-SUCCESS returns
non-nil, as for a draft that stays, which you are writing in, or the
draft of an agent's offer, which leaves you where you are."
  (roost--remember-host host)
  (when (and (roost--field task 'repo) (not (roost--conversation-p task)))
    (roost--remember-project (roost--project-directory (cons (cons 'host host) task))))
  (let ((found (roost--field task 'alreadyMade)))
    ;; Unless it went since a list showed it, as you finished it: the reply
    ;; can take longer to come than that.
    (setq task (roost--cache-reply host task (gethash (list host (roost--field task 'id)) roost--went)))
    (roost-watch-mode 1)
    ;; It opens where the draft closes.
    (roost--when-out-of-minibuffer
     (lambda ()
       (let* ((stayed (funcall stayed))
              (kept (when on-success (funcall on-success task found))))
         (roost--redraw)
         ;; Unless it went while you were in the minibuffer: opening it
         ;; would bring it back.
         (when (and stayed (not kept) (gethash (roost--key task) roost--tasks))
           (roost-open-task task))))))
  ;; By the name it has: asked again, its host answers with the task it made.
  (if (roost--conversation-p task)
      (message "Roost started %s on %s" (or (roost--field task 'name) name) (roost--host-label host))
    (message "Roost created %s on %s from %s%s; it merges into %s"
             (or (roost--field task 'name) name) (roost--host-label host)
             (roost--field task 'baseRef)
             (if-let* ((forked (roost--field task 'forkedFrom)))
                 (format ", going on with %s's conversation" (alist-get 'name forked))
               "")
             (roost--field task 'integrationBranch))))

(defun roost--conversation-p (task)
  "Whether TASK is a conversation, in no project of yours."
  (eq (roost--field task 'conversation) t))

(defun roost--refuse-conversation (task why)
  "Refuse to act on TASK if it is a conversation, saying it WHY."
  (when (roost--conversation-p task)
    (user-error "%s is a conversation, which %s; x ends it" (roost--field task 'name) why)))

(defun roost--conversation-name ()
  "A name for a new conversation: when it starts, and a number if taken."
  (let* ((base (format-time-string "Conversation %H:%M"))
         (taken (mapcar (lambda (task) (roost--field task 'name)) (roost-tasks)))
         (name base) (n 1))
    (while (member name taken)
      (setq name (format "%s (%d)" base (cl-incf n))))
    name))

;;;###autoload
(defun roost-new-conversation (&optional host)
  "Start a conversation with an agent, in no project of yours.
It opens the agent's own terminal at once, with nothing to write first:
you say what you want there.  Its host keeps it in a folder of its own,
so it has no branch to merge, and `roost-retire' ends it.  On HOST, nil
for this machine; with a prefix argument, ask which."
  (interactive
   (list (when current-prefix-arg
           (let* ((here "This machine")
                  (pick (completing-read "Conversation on: " (cons here (roost--hosts)) nil nil)))
             (unless (or (string-empty-p pick) (equal pick here)) pick)))))
  (roost--create-task (if host (roost--host-directory host "~") (expand-file-name "~/"))
                      (roost--conversation-name)
                      nil nil nil nil nil '((conversation . t))))

;;;###autoload
(defun roost-new-task (&optional directory name base prompt agent)
  "Start a new coding agent task.
Interactively, open a buffer to choose the project, agent and starting
point and to write the prompt; \\<roost-compose-mode-map>\\[roost-compose-submit] creates the task.
An active region, or the Org entry at point, starts the prompt; code is
quoted with its file and lines.  With a prefix argument, the defaults
fork the current task: its commits, and, once its agent has a
conversation, that conversation and the task's uncommitted changes,
which \\<roost-compose-mode-map>\\[roost-compose-set-conversation] in the draft trades for a new conversation.

Called with DIRECTORY, create an AGENT task NAME there directly, from
BASE with optional PROMPT.  DIRECTORY may be a TRAMP path.  Nil BASE uses
the primary checkout's current branch, even when DIRECTORY is a task
worktree; explicit HEAD uses DIRECTORY.  Nil AGENT uses
`roost-default-agent'."
  (interactive)
  (if directory
      (roost--create-task directory name base prompt agent)
    (roost--compose current-prefix-arg)))

;;;###autoload
(defun roost-draft-task (prompt &optional directory)
  "Open the new task draft with PROMPT, in the project DIRECTORY is in.
Without DIRECTORY, the project is the one you are in, as for
`roost-new-task'.  A draft you have written in already is kept as it is.
For commands of your own that start a task from what they show, such
as a mail or a bug report."
  (roost--compose nil (cons prompt nil) (and directory (roost--draft-directory directory))))

;;;###autoload
(defun roost-new-task-from-region (start end)
  "Start a new task from the text between START and END.
Code is quoted with its file and lines, and you write above it.  The
same as `roost-new-task' with the region active, for Embark's region
actions."
  (interactive "r")
  (roost--compose nil (roost--region-seed start end)))

;;;###autoload
(defun roost-new-task-from-file (file)
  "Start a new task about FILE, in the project it is in.
The draft names FILE from the top of its checkout."
  (interactive (list (read-file-name "New task about: ")))
  (setq file (expand-file-name file))
  (roost--compose nil (cons (concat "\n\n" (roost--file-quote file)) t)
                  (roost--draft-directory (file-name-directory file))))

(defun roost--checkout-of (file)
  "The top of FILE's checkout, as a directory, or nil.
Git's checkout of it.  On another host, looking for that takes a round
trip for each directory, while you wait, so first a task's worktree or
a project Roost knows, by path, and nothing that would connect to a host
TRAMP isn't connected to."
  (let ((directory (file-name-directory file)))
    (or (and (file-remote-p directory)
             (or (when-let* ((task (roost--task-in-directory directory)))
                   (file-name-as-directory (roost--remote-directory task)))
                 (roost--known-project-of directory)))
        ;; Here Git answers at once, nested repositories and all.
        (and (roost--may-look-in-p directory)
             (ignore-errors (locate-dominating-file file ".git"))))))

;;;###autoload
(defun roost-new-task-from-url (url)
  "Start a new task about URL, such as a bug report or a page of documentation."
  (interactive (list (read-string "New task about: " (thing-at-point 'url t))))
  (roost--compose nil (cons (concat "\n\n" url) t)))

;;;###autoload
(defun roost-new-task-from-diagnostic ()
  "Start a new task about the Flymake diagnostics at point.
The draft quotes each with its file and line, then the lines they are
on, and you write above them."
  (interactive)
  (let ((diagnostics (and (bound-and-true-p flymake-mode)
                          (or (flymake-diagnostics (point))
                              (flymake-diagnostics (line-beginning-position) (line-end-position))))))
    (unless diagnostics
      (user-error "No Flymake diagnostic here"))
    (setq diagnostics (sort (copy-sequence diagnostics)
                            (lambda (a b) (< (flymake-diagnostic-beg a) (flymake-diagnostic-beg b)))))
    (let* ((start (save-excursion (goto-char (flymake-diagnostic-beg (car diagnostics)))
                                  (line-beginning-position)))
           (end (save-excursion (goto-char (apply #'max (mapcar #'flymake-diagnostic-end diagnostics)))
                                (line-end-position)))
           (file (roost--buffer-file-quote)))
      (roost--compose
       nil (cons (concat "\n\n"
                         (mapconcat (lambda (diagnostic)
                                      (format "%s:%d: %s" file
                                              (roost--source-line (flymake-diagnostic-beg diagnostic))
                                              (string-trim (flymake-diagnostic-text diagnostic))))
                                    diagnostics "\n")
                         "\n\n" (string-trim-right (buffer-substring-no-properties start end)))
                 t)))))

(defun roost--draft-directory (directory)
  "The project a new task drafted about DIRECTORY goes to.
DIRECTORY's checkout, or a project Roost knows it is in."
  (with-temp-buffer
    (setq default-directory (file-name-as-directory (expand-file-name directory)))
    (roost--compose-default-directory nil nil)))

;;;; Composing a new task

(defconst roost--compose-buffer "*roost new task*")

(defvar-local roost--compose-fields nil
  "Plist of the draft task: :directory :agent :base :integration :name :source.
A draft of an agent's offer also has :parent, the key of the task whose
agent offered it, which the task it makes shows under, and :offer, the
offer's ID, which its host drops then, should taking it have failed.
A fork also has :source-id and :source-agent, its task's, and
:conversation, whether it goes on with that task's conversation.
A draft that makes several attempts at its prompt has :attempts: how
many, each by its agent, or the agents of those after the first.")

(defvar-local roost--compose-body nil
  "Marker at the start of the prompt text.")
(defvar-local roost--compose-timer nil)

(defvar-local roost--compose-checkout-branch nil
  "The draft's project directory and its primary checkout's branch, as a cons.
Read once for each project: the fields are redrawn as you write.")

(defun roost--checkout-branch (directory)
  "The branch checked out in the primary checkout of DIRECTORY's project, or nil.
Nil too on another host, where reading it would hold up the draft."
  (unless (file-remote-p directory)
    (when-let* ((list (roost--git-in directory "worktree" "list" "--porcelain"))
                ;; The primary checkout comes first.
                (first (car (split-string list "\n\n")))
                ((string-match "^branch refs/heads/\\(.+\\)$" first)))
      (match-string 1 first))))

(defun roost--compose-branch (directory)
  "The branch a draft in DIRECTORY starts from by default, or nil if unknown."
  (unless (equal (car roost--compose-checkout-branch) directory)
    (setq roost--compose-checkout-branch
          (cons directory (and directory (roost--checkout-branch directory)))))
  (cdr roost--compose-checkout-branch))
(defvar-local roost--compose-submitting nil
  "Non-nil while the drafted task is being created.")

(defvar-local roost--compose-asked nil
  "The project directory and the ID the draft last asked to create its task with.
A list, with what it said each time it asked with that ID, from
`roost--compose-what', or nil once it asked with that ID for different
things: which of them made a task isn't known then.  The ID is the same
each time for the same project, so its host makes the task once, however
often you ask: it answers again with the task it made.")

(defvar-keymap roost-compose-mode-map
  :doc "Keys for drafting a new Roost task."
  "C-c C-c" #'roost-compose-submit
  "C-c C-k" #'roost-compose-cancel
  "C-c C-p" #'roost-compose-set-project
  "C-c C-a" #'roost-compose-set-agent
  "C-c C-b" #'roost-compose-set-base
  "C-c C-n" #'roost-compose-set-name
  "C-c C-t" #'roost-compose-set-issue
  "C-c C-f" #'roost-compose-set-conversation
  "C-c C-x" #'roost-compose-set-attempts)

(define-derived-mode roost-compose-mode text-mode "Roost New Task"
  "Draft a coding agent task.  Write the prompt below the line.
\\{roost-compose-mode-map}"
  (setq-local header-line-format '(:eval (roost--compose-header)))
  (add-hook 'after-change-functions #'roost--compose-changed nil t)
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-compose-mode 'insert)
  (roost--quiet-display))

(defvar-local roost--draft-note nil
  "What a draft's header line says in place of its keys, or nil.
As that its task is being created, or why sending it failed.")

(defun roost--clicks-p ()
  "Whether the selected frame reads clicks.
A text frame does with `xterm-mouse-mode'."
  (or (display-graphic-p) (bound-and-true-p xterm-mouse-mode)))

(defun roost--header-text (text)
  "TEXT for a header line, which takes a percent sign for a format of its own."
  (string-replace "%" "%%" text))

(defun roost--draft-header (text buttons &optional busy)
  "A draft's header line: TEXT, or the draft's note, then BUTTONS at the right.
BUTTONS are as `roost--header-buttons' takes them, shown where clicks
reach Emacs, and not while BUSY.  Text that doesn't fit beside them is
cut short, with all of it in its help-echo: they are how a hand on the
mouse tries again, or gives up."
  (let ((text (or roost--draft-note text)))
    (if (or busy (not (roost--clicks-p)))
        (roost--header-text text)
      (let* ((buttons (roost--header-buttons buttons))
             (width (string-pixel-width buttons))
             (room (max 0 (- (window-max-chars-per-line) (ceiling width (frame-char-width)) 2))))
        (concat (roost--header-text
                 (if (> (string-width text) room)
                     (propertize (truncate-string-to-width text room nil nil "…")
                                 'help-echo (string-trim text))
                   text))
                (propertize " " 'display `(space :align-to (- right (,(+ width (frame-char-width))))))
                buttons)))))

(defun roost--compose-header ()
  "The new task draft's header line: its keys, then buttons."
  (roost--draft-header
   (substitute-command-keys
    (concat "\\<roost-compose-mode-map> \\[roost-compose-submit] create · \\[roost-compose-cancel] cancel"
            (when (roost--clicks-p) " · click a field to change it")))
   '((" Cancel " roost-compose-cancel roost-note-box-button
      "mouse-1 or \\<roost-compose-mode-map>\\[roost-compose-cancel]: discard the draft")
     (" Create " roost-compose-submit roost-note-box-default-button
      "mouse-1 or \\<roost-compose-mode-map>\\[roost-compose-submit]: create the task"))
   roost--compose-submitting))

(defun roost--compose-default-directory (task fork)
  "Default project for a new task, given the TASK in context and FORK.
On a project's heading in the dashboard or sidebar, that project."
  (cond ((and task (not (roost--conversation-p task)))
         (if fork (roost--remote-directory task) (roost--project-directory task)))
        ((get-text-property (point) 'roost-directory))
        ;; On another host, looking there takes a round trip for each
        ;; directory VC tries, and connects first if TRAMP hasn't, while you
        ;; wait: so first a project Roost knows the directory is in, by name.
        ((and (file-remote-p default-directory)
              ;; A task's worktree, as Git would find it.
              (or (when-let* ((task (roost--task-in-directory default-directory)))
                    (roost--remote-directory task))
                  (roost--known-project-of default-directory))))
        ((and (roost--may-look-in-p default-directory) (ignore-errors (vc-root-dir))))
        ((roost--known-project-of default-directory))
        ;; Buffers VC does not track, such as Dired or a shell, in a checkout.
        ((when-let* (((roost--may-look-in-p default-directory))
                     (root (ignore-errors (locate-dominating-file default-directory ".git"))))
           (file-name-as-directory (expand-file-name root))))
        ((car (roost--known-projects)))))

(defun roost--may-look-in-p (directory)
  "Whether looking in DIRECTORY opens no connection.
It does not when DIRECTORY is local, or on a host TRAMP is connected to."
  (or (not (file-remote-p directory)) (file-remote-p directory nil t)))

(defun roost--known-project-of (directory)
  "The project Roost knows that DIRECTORY is in, the deepest, or nil.
By SSH destination and path alone, whatever TRAMP method names them, so
a remote DIRECTORY opens no connection."
  (when-let* ((place (roost--host-and-path directory)))
    (cdr (car (sort (seq-filter (lambda (project)
                                  (and (equal (car (car project)) (car place))
                                       (string-prefix-p (cdr (car project)) (cdr place))))
                                (seq-keep (lambda (project)
                                            (when-let* ((at (roost--host-and-path project)))
                                              (cons at project)))
                                          (roost--known-projects)))
                    (lambda (a b) (> (length (cdr (car a))) (length (cdr (car b))))))))))

(defun roost--host-and-path (directory)
  "DIRECTORY's SSH destination, nil if local, and its path there.
As (HOST . PATH), HOST with its user, as `roost--directory-host' gives
it.  By name, without connecting; nil for a name TRAMP can't read, such
as one with a method not loaded."
  (ignore-errors
    (cons (roost--directory-host directory)
          (file-name-as-directory (file-local-name (expand-file-name directory))))))

(defun roost--compose-seed ()
  "Prompt text from the current buffer, or nil.
The active region, with its file and lines when it is code, or else the
Org entry at point or on the agenda line: its heading and text without
planning or drawers.
The cdr is non-nil when the writer should start above the text."
  (cond
   ((use-region-p) (roost--region-seed (region-beginning) (region-end)))
   ;; An error or a match in a compilation or grep buffer, with its place.
   ((and (derived-mode-p 'compilation-mode)
         (text-property-not-all (line-beginning-position) (line-end-position) 'compilation-message nil))
    (let ((line (string-trim (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))
      (cons (concat "\n\n" (if-let* ((file (roost--compilation-file))) (roost--quoting line file) line))
            t)))
   ((and (derived-mode-p 'org-mode) (not (org-before-first-heading-p)))
    (cons (roost--org-entry-text) nil))
   ((and (derived-mode-p 'org-agenda-mode)
         (markerp (get-text-property (line-beginning-position) 'org-hd-marker)))
    (let ((marker (get-text-property (line-beginning-position) 'org-hd-marker)))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char marker)
            (cons (roost--org-entry-text) nil))))))))

(defun roost--region-seed (start end)
  "Prompt text from the text between START and END, as `roost--compose-seed'.
Code is quoted with its file and lines, and the writer starts above it."
  (let ((last (if (and (> end start) (eq (char-before end) ?\n)) (1- end) end))
        (text (buffer-substring-no-properties start end)))
    (if (derived-mode-p 'prog-mode)
        (cons (format "\n\n%s:%d-%d\n\n%s" (roost--buffer-file-quote)
                      (roost--source-line start) (roost--source-line last)
                      (string-trim-right text))
              t)
      (cons (string-trim text) nil))))

(defvar org-src--beg-marker)

(defun roost--org-src-start ()
  "Where the Org source block edited in this buffer starts, or nil.
A marker in the Org buffer, at the block's first line, for a buffer
`org-edit-special' opened."
  (when-let* (((bound-and-true-p org-src-mode))
              ((markerp org-src--beg-marker))
              ((buffer-live-p (marker-buffer org-src--beg-marker))))
    org-src--beg-marker))

(defun roost--source-file ()
  "The file the current buffer's text is from, or nil.
The current buffer's file, or its base buffer's for an indirect one, as
`clone-indirect-buffer' makes; for an Org source block being edited,
the Org file."
  (let ((buffer (if-let* ((start (roost--org-src-start))) (marker-buffer start) (current-buffer))))
    (buffer-file-name (or (buffer-base-buffer buffer) buffer))))

(defun roost--source-line (position)
  "POSITION's line in the file the current buffer's text is from.
Counted in the whole file, though the buffer is narrowed, and for an Org
source block being edited, from the top of the Org file."
  (+ (line-number-at-pos position t)
     (if-let* ((start (roost--org-src-start)))
         (with-current-buffer (marker-buffer start) (1- (line-number-at-pos start t)))
       0)))

(defun roost--file-quote (file)
  "FILE as a draft names it: from the top of its checkout, or in full.
From its checkout, it is marked as quoting the file; see `roost--quoting'."
  (if-let* ((root (roost--checkout-of file)))
      (roost--quoting (file-relative-name (file-local-name file) (file-local-name root)))
    (abbreviate-file-name file)))

(defun roost--buffer-file-quote ()
  "The file the current buffer's text is from, as a draft names it.
Or the buffer's name, for text from no file.  See `roost--source-file'
and `roost--file-quote'."
  (if-let* ((file (roost--source-file)))
      (roost--file-quote file)
    (buffer-name)))

(defun roost--quoting (text &optional file)
  "TEXT, marked as quoting FILE, by default TEXT itself.
FILE is a path from the top of its checkout.  The draft names the tasks
that change a file its prompt quotes, while the quote is there."
  (propertize text 'roost-file (or file text)))

(declare-function compilation--message->loc "compile")

(defun roost--compilation-file ()
  "The file of the compilation error or grep match on point's line, or nil.
As a path from the top of its checkout, unless that is on a host TRAMP
is not connected to."
  (when-let* ((at (text-property-not-all (line-beginning-position) (line-end-position)
                                         'compilation-message nil))
              ;; ((FILE DIRECTORY) FORMATS ...), FILE a buffer for one compiled.
              (spec (ignore-errors
                      (car (nth 2 (compilation--message->loc
                                   (get-text-property at 'compilation-message))))))
              ((stringp (car spec)))
              (file (expand-file-name (car spec) (expand-file-name (or (cadr spec) default-directory))))
              ((roost--may-look-in-p file))
              (root (ignore-errors (locate-dominating-file file ".git"))))
    (file-relative-name file root)))

(defun roost--org-marker ()
  "Marker at the Org heading at point or on the agenda line, or nil.
In an indirect buffer, as `org-tree-to-indirect-buffer' makes, the
marker is in its base buffer, which outlives it: Org closes the one it
made last as it makes the next."
  (cond ((and (derived-mode-p 'org-mode) (not (org-before-first-heading-p)))
         (let ((base (buffer-base-buffer)))
           (save-excursion
             (org-back-to-heading t)
             (set-marker (make-marker) (point)
                         (if (and base (with-current-buffer base (derived-mode-p 'org-mode)))
                             base
                           (current-buffer))))))
        ((derived-mode-p 'org-agenda-mode)
         (when-let* ((marker (get-text-property (line-beginning-position) 'org-hd-marker))
                     ((markerp marker)))
           (copy-marker marker)))))

(defun roost--org-linked-id ()
  "Id of the task linked to the Org entry at point or on the agenda line."
  (cond ((and (derived-mode-p 'org-mode) (not (org-before-first-heading-p)))
         (org-entry-get nil "ROOST_TASK"))
        ((derived-mode-p 'org-agenda-mode)
         (when-let* ((marker (get-text-property (line-beginning-position) 'org-hd-marker))
                     ((markerp marker))
                     ((buffer-live-p (marker-buffer marker))))
           (with-current-buffer (marker-buffer marker)
             (org-entry-get marker "ROOST_TASK"))))))

(defun roost--org-link (marker task)
  "Record TASK's id on the Org entry at MARKER; see `roost-org-link-tasks'."
  (when (and roost-org-link-tasks (markerp marker) (buffer-live-p (marker-buffer marker)))
    (with-current-buffer (marker-buffer marker)
      (org-entry-put marker "ROOST_TASK" (roost--field task 'id)))))

(defun roost--org-entry-text ()
  "The Org entry at point: its heading, then its text.
Planning lines and drawers are left out."
  (save-excursion
    (org-back-to-heading t)
    (let* ((title (org-get-heading t t t t))
           (end (org-entry-end-position))
           (start (progn (org-end-of-meta-data t) (point)))
           (body (if (< start end) (string-trim (buffer-substring-no-properties start end)) "")))
      (if (string-empty-p body) title (concat title "\n\n" body)))))

(defun roost--compose (&optional fork seed directory)
  "Open the new task buffer.  FORK defaults to the current task's HEAD.
SEED, as `roost--compose-seed' makes one, starts the prompt in place of
what is at point, and DIRECTORY is its project in place of where you are.
Given with no SEED, DIRECTORY moves a written draft there too, unless
`roost--compose-tied' says otherwise."
  (let* ((task (roost--task-at-point))
         (fork (and fork task))
         (given seed)
         (project directory)
         (seed (or seed (roost--compose-seed)))
         (org (and seed (not given) (not (use-region-p)) (roost--org-marker)))
         ;; Where you are, before the draft becomes the current buffer.
         (directory (or directory (roost--compose-default-directory task fork)))
         (buffer (get-buffer roost--compose-buffer))
         (fresh (not buffer))
         ;; Given with no text to add, as by a click on a project.
         (chosen (and project (not given))))
    (setq buffer (or buffer (get-buffer-create roost--compose-buffer)))
    (with-current-buffer buffer
      (when fresh
        (roost-compose-mode)
        (setq roost--compose-body (copy-marker (point-min))))
      ;; Its branch is read again, written or not, in case you have
      ;; switched it since.
      (setq roost--compose-checkout-branch nil)
      ;; An untouched draft follows the current context; a written one is kept.
      (when (or fresh fork (string-empty-p (roost--compose-prompt)))
        (let ((agent (when fork (or (roost--field task 'agent) "claude")))
              (talked (when fork (or (roost--field task 'agentSession) (roost--field task 'claudeSession)))))
          (setq roost--compose-fields
                (list :directory directory
                      ;; A fork goes on with the task's conversation, when
                      ;; it has one, and so with its agent.
                      :agent (if talked agent roost-default-agent)
                      :base (when fork "HEAD")
                      :integration (when fork (roost--compose-integration directory "HEAD"))
                      :source (when fork (roost--field task 'name))
                      :source-id (when fork (roost--field task 'id))
                      :source-agent agent
                      :conversation (and talked t)))))
      (let ((here (plist-get roost--compose-fields :directory)))
        ;; However it is spelled.
        (when (and chosen (not (and here (equal (roost--project-place here) (roost--project-place project)))))
          (if-let* ((tied (and here (roost--compose-tied))))
              (message "The draft stays in %s, as %s" (roost--project-label here) tied)
            (roost--compose-move project))))
      (roost--compose-render)
      (goto-char (point-max))
      (if (not (and seed (string-empty-p (roost--compose-prompt))))
          (when org (set-marker org nil))
        (setq roost--compose-fields (plist-put roost--compose-fields :org org))
        (delete-region roost--compose-body (point-max))
        (insert (car seed))
        (goto-char (if (cdr seed) roost--compose-body (point-max)))
        (roost--compose-render)))
    ;; In the window you are in, as Magit does, rather than a split that
    ;; squeezes an agent's terminal; cancelling gives the window back.
    (roost--leave-side-window)
    (roost--pop-to-buffer-in-place buffer)))

(defun roost--tiled-pane-window-p (window)
  "Whether WINDOW shows a pane of a terminal tmux-control has tiled.
tmux-control arranges those windows itself: a buffer shown in one is
taken back at the next change of layout, and the selection with it."
  (with-current-buffer (window-buffer window)
    (and (derived-mode-p 'tmux-control-mode)
         (fboundp 'tmux-control-tiled-p)
         (tmux-control-tiled-p))))

(defun roost--display-beside-tiles (buffer alist)
  "Display BUFFER in a window of the frame's that no terminal is in, or a new one.
A `display-buffer' action, with its action ALIST, for when the selected
window is a tiled terminal's pane, which BUFFER would not keep."
  (if-let* ((window (seq-find (lambda (window)
                                ;; Nor one kept for its buffer, as a note's on
                                ;; a text terminal.
                                (not (or (window-parameter window 'window-side)
                                         (window-dedicated-p window)
                                         (with-current-buffer (window-buffer window)
                                           (derived-mode-p 'tmux-control-mode)))))
                              (window-list nil 'nomini))))
      (window--display-buffer buffer window 'reuse alist)
    (display-buffer-at-bottom buffer alist)))

(defun roost--pop-to-buffer-in-place (buffer)
  "Show BUFFER in the selected window, and select it.
When that window is a tiled terminal's pane, use another, or a new one."
  (pop-to-buffer buffer (if (roost--tiled-pane-window-p (selected-window))
                            '((display-buffer-reuse-window roost--display-beside-tiles))
                          '((display-buffer-reuse-window display-buffer-same-window)))))

(defun roost--compose-prompt ()
  "The draft's prompt text."
  (string-trim (buffer-substring-no-properties roost--compose-body (point-max))))

(defun roost--compose-name ()
  "The draft's explicit name, or one derived from its prompt.
A task started from an issue leads with its number, or a Jira work
item's key, which Jira finds the branch by."
  (or (plist-get roost--compose-fields :name)
      (let ((derived (roost--name-from-prompt (roost--compose-prompt)))
            (issue (when-let* ((issue (plist-get roost--compose-fields :issue)))
                     (or (alist-get 'key issue) (alist-get 'number issue)))))
        (if (and issue (not (string-empty-p derived)))
            (format "%s-%s" issue derived)
          derived))))

(defun roost--compose-field (label value command &optional note)
  "Insert field LABEL showing VALUE as a button running COMMAND, then NOTE."
  (insert (propertize (format "%-9s" label) 'font-lock-face 'roost-dim))
  ;; As it is, without a link's underline: what you chose is what the
  ;; draft says, and it lights up under the mouse.
  (insert-text-button value 'action (lambda (_) (call-interactively command))
                      'follow-link t 'face 'roost-field 'font-lock-face 'roost-field
                      'help-echo (format "mouse-1 or RET: change %s" (downcase label)))
  ;; Its key quietly, where the display can draw quietly: six of them in
  ;; a key's own colours are louder than the fields they change.
  (let ((key (substitute-command-keys (format "\\<roost-compose-mode-map>\\[%s]" command))))
    (insert (propertize "  " 'font-lock-face 'roost-dim 'roost-field-gap t)
            (propertize (concat (if (roost--decorated-p) (substring-no-properties key) key)
                                (if note (concat " · " note) ""))
                        'font-lock-face 'roost-dim)))
  (insert "\n"))

(defun roost--compose-align-keys (start end)
  "Draw the keys of the fields between START and END in a column.
Two past the longest value, but for one that would take them past the
middle of a wide window: its key follows it.  Only where the display
can; the text is the same either way."
  (when (roost--decorated-p)
    (let (gaps)
      (save-excursion
        (goto-char start)
        (while (setq start (text-property-any (point) end 'roost-field-gap t))
          (goto-char start)
          (push (cons start (current-column)) gaps)
          (goto-char (or (next-single-property-change start 'roost-field-gap nil end) end))))
      (when-let* ((near (seq-filter (lambda (gap) (<= (cdr gap) 56)) gaps))
                  (column (+ 2 (apply #'max (mapcar #'cdr near)))))
        (pcase-dolist (`(,at . ,_) near)
          (put-text-property at (next-single-property-change at 'roost-field-gap nil end)
                             'display `(space :align-to ,column)))))))

(defun roost--compose-render ()
  "Redraw the draft's fields above the prompt, leaving the prompt untouched."
  (let* ((inhibit-read-only t)
         (inhibit-modification-hooks t)
         (undo buffer-undo-list)
         (body (marker-position roost--compose-body))
         (buffer-undo-list t)
         (fields roost--compose-fields)
         (derived (roost--compose-name))
         (changing (roost--compose-changing))
         ;; Point's offset into the prompt, so rewriting the fields keeps it;
         ;; in the fields, its line and column, as on a button there; on a
         ;; task's name, that task, wherever it is listed now.
         (offset (max 0 (- (point) roost--compose-body)))
         (field (when (< (point) roost--compose-body)
                  (cons (line-number-at-pos) (current-column))))
         (named (get-text-property (point) 'roost-draft-task)))
    (save-excursion
      (delete-region (point-min) roost--compose-body)
      (goto-char (point-min))
      (insert (propertize (if-let* ((parent (plist-get fields :parent)))
                              (format "New task, offered by %s"
                                      (if-let* ((task (gethash parent roost--tasks)))
                                          (roost--field task 'name)
                                        "a task Roost no longer has"))
                            "New task")
                          'font-lock-face 'roost-title)
              "\n\n")
      (let* ((directory (plist-get fields :directory))
             (base (plist-get fields :base))
             (name (plist-get fields :name))
             (branch (roost--compose-branch directory))
             (current (or branch "the project's current branch")))
        (roost--compose-field "Project" (if directory (roost--project-label directory) "Choose a project…")
                              #'roost-compose-set-project)
        (roost--compose-field "Agent" (plist-get fields :agent) #'roost-compose-set-agent)
        ;; How many tasks it makes from the prompt, and by which agents.
        (let ((agents (roost--compose-agents)))
          (roost--compose-field "Attempts" (cond ((integerp (plist-get fields :attempts))
                                                  (number-to-string (length agents)))
                                                 ((cdr agents) (string-join agents ", "))
                                                 (t "1"))
                                #'roost-compose-set-attempts
                                (when (cdr agents)
                                  (substitute-command-keys
                                   "each a task of its own; \\<roost-dashboard-mode-map>\\[roost-compare-attempts] on one compares them"))))
        (roost--compose-field "Start" (cond ((plist-get fields :source)
                                            (format "%s of %s" base (plist-get fields :source)))
                                           ;; By its short name, as an offer's is given in full.
                                           (base (string-remove-prefix "refs/heads/" base))
                                           (t current))
                              #'roost-compose-set-base
                              ;; Not "the project's current branch" twice over.
                              (when (or base branch)
                                (concat (when (plist-get fields :source)
                                          (if (roost--compose-continues)
                                              "fork: includes its commits and uncommitted changes; "
                                            "fork: includes its commits; "))
                                        (pcase (and base (plist-get fields :integration))
                                          ('nil (concat "merges into " current))
                                          ("" "no branch to merge into")
                                          (into (concat "merges into " into))))))
        (when-let* ((source (plist-get fields :source)))
          (roost--compose-field "Context" (if (roost--compose-continues)
                                              (format "%s's conversation" source)
                                            "a new conversation")
                                #'roost-compose-set-conversation
                                (cond ((roost--compose-continues) "its agent hears it now works in a new worktree")
                                      ((and (plist-get fields :conversation)
                                            (not (equal (plist-get fields :agent)
                                                        (plist-get fields :source-agent))))
                                       (format "%s can't continue %s's"
                                               (plist-get fields :agent) (plist-get fields :source-agent))))))
        (roost--compose-field "Issue" (if-let* ((issue (plist-get fields :issue)))
                                          (format "%s %s" (roost--issue-label issue)
                                                  (or (alist-get 'title issue) ""))
                                        "none")
                              #'roost-compose-set-issue
                              (when-let* ((issue (plist-get fields :issue)))
                                (if (alist-get 'key issue)
                                    "the branch leads with its key"
                                  "the pull request will close it")))
        (roost--compose-field "Name" (cond (name)
                                          ((string-empty-p derived) "from the prompt")
                                          (t derived))
                              #'roost-compose-set-name
                              (unless (or name (string-empty-p derived)) "from the prompt")))
      (roost--compose-align-keys (point-min) (point))
      (roost--compose-insert-changing changing)
      (insert (if-let* ((colour (and (display-graphic-p) (roost--hairline))))
                  ;; Drawn as one line across the window, of the same text.
                  (propertize (make-string 60 ?─) 'font-lock-face 'roost-dim
                              'display '(space :align-to right)
                              'face (list :strike-through colour))
                (propertize (make-string 60 ?─) 'font-lock-face 'roost-dim))
              "\n"
              (propertize "Describe the task for the agent below.\n" 'font-lock-face 'roost-dim))
      (add-text-properties (point-min) (point)
                           '(read-only "Write the prompt below the fields" rear-nonsticky t
                             front-sticky t))
      (set-marker roost--compose-body (point)))
    (roost--shift-undo undo (- roost--compose-body body))
    (cond ((not field)
           (goto-char (min (point-max) (+ roost--compose-body offset))))
          (named
           ;; Gone from the list, nowhere a key would open another.
           (goto-char (point-min))
           (while (and (< (point) roost--compose-body)
                       (not (equal (get-text-property (point) 'roost-draft-task) named)))
             (goto-char (next-single-property-change (point) 'roost-draft-task nil roost--compose-body))))
          (t
           (goto-char (point-min))
           (forward-line (1- (car field)))
           (move-to-column (cdr field))
           (goto-char (min (point) roost--compose-body))
           (when (get-text-property (point) 'roost-draft-task)
             (goto-char roost--compose-body))))))

(defun roost--shift-undo (list delta)
  "Add DELTA to each position in LIST, the draft's undo list.
Undo goes by position, and the fields above the prompt change length out
of its sight.  In place: `pending-undo-list', as you undo again and
again, is a tail of it."
  (unless (zerop delta)
    (while (consp list)
      (let ((entry (car list)))
        (pcase entry
          ((pred integerp) (setcar list (+ entry delta)))
          (`(,(and (pred integerp) start) . ,(and (pred integerp) end))
           (setcar entry (+ start delta))
           (setcdr entry (+ end delta)))
          ;; Negative when point was at the end of the text deleted.
          (`(,(pred stringp) . ,(and (pred integerp) position))
           (setcdr entry (if (< position 0) (- position delta) (+ position delta))))
          (`(nil ,_ ,_ ,(and (pred integerp) start) . ,(and (pred integerp) end))
           (setcdr (cddr entry) (cons (+ start delta) (+ end delta))))))
      (setq list (cdr list)))))

(defun roost--compose-quoted-files ()
  "The files the draft's prompt quotes, as paths from the top of the checkout.
Those that the text started from where you were marks, with
`roost--quoting', and that you haven't deleted since."
  (let ((pos roost--compose-body) files)
    (while (< pos (point-max))
      (when-let* ((file (get-text-property pos 'roost-file)))
        (unless (member file files) (push file files)))
      (setq pos (next-single-property-change pos 'roost-file nil (point-max))))
    (nreverse files)))

(defun roost--compose-changing ()
  "The tasks of the draft's project that change files its prompt quotes.
As `roost--changing' gives them, from what Roost last measured of each:
while it watches, that is after their agents' latest edits."
  (when-let* ((directory (plist-get roost--compose-fields :directory))
              (files (roost--compose-quoted-files))
              (place (roost--host-and-path directory)))
    (let* ((host (car place))
           (path (directory-file-name (cdr place)))
           ;; Through symbolic links, as the helper names the project; a
           ;; remote one as it is, which opens no connection.
           (real (if host path (directory-file-name (file-truename path))))
           ;; A task's worktree is of its project.
           (repo (or (seq-some (lambda (task)
                                 (and (equal (roost--field task 'host) host)
                                      (member (roost--field task 'worktree) (list path real))
                                      (roost--field task 'repo)))
                               (roost-tasks))
                     real)))
      (roost--changing host repo files))))

(defvar-local roost--compose-changing-shown nil
  "What the draft last said of the tasks that change files it quotes.
Each (KEY NAME . FILES), so that a refresh redraws it only when that changes.")

(defun roost--compose-changing-summary (changing)
  "CHANGING, from `roost--compose-changing', as `roost--compose-changing-shown'."
  (mapcar (lambda (entry)
            (cons (roost--key (car entry)) (cons (roost--field (car entry) 'name) (cdr entry))))
          changing))

(defun roost-compose-open-task (&optional event)
  "Open the task whose name is at point in the draft, or clicked in EVENT.
The draft names the tasks that change files it quotes.  Roost's menu,
left open, closes rather than refusing the click."
  (interactive (list last-nonmenu-event))
  (when (mouse-event-p event)
    (mouse-set-point event))
  (or (push-button) (user-error "No task's name here")))

(defvar-keymap roost--compose-task-map
  :doc "Keys on a task's name in the draft: a click or RET opens it."
  :parent button-map
  "RET" #'roost-compose-open-task
  "<mouse-2>" #'roost-compose-open-task)

(defun roost--compose-insert-changing (changing)
  "Name the tasks in CHANGING, each opening on a click.
CHANGING is what `roost--compose-changing' gives: the tasks that change
files the draft quotes.  Whether to start the task anyway, wait, or
give the work to one of them is yours: this only says so."
  (setq roost--compose-changing-shown (roost--compose-changing-summary changing))
  (when changing
    (insert "\n"
            (roost--changing-text
             changing "already changes" "already change"
             (lambda (task)
               (let ((key (roost--key task))
                     (name (roost--field task 'name)))
                 (make-text-button (copy-sequence name) nil
                                   'follow-link t 'font-lock-face 'roost-field
                                   'keymap roost--compose-task-map 'roost-draft-task key
                                   'help-echo (format "mouse-1 or RET: open %s" name)
                                   'action (lambda (_)
                                             (roost-open-task
                                              (or (gethash key roost--tasks)
                                                  (user-error "%s is no longer listed" name))
                                              t))))))
            "\n")))

(defun roost--compose-changed (&rest _)
  "Refresh the fields soon after each edit to the prompt.
The name derives from it, and a quote you delete no longer counts."
  (when (timerp roost--compose-timer) (cancel-timer roost--compose-timer))
  (let ((buffer (current-buffer)))
    (setq roost--compose-timer
          (run-with-idle-timer 0.3 nil (lambda ()
                                         (when (buffer-live-p buffer)
                                           (with-current-buffer buffer
                                             (roost--compose-render))))))))

(defun roost--compose-redraw-changing ()
  "Redraw the draft if the tasks that change files it quotes have changed.
For `roost--redraw', as new measurements of the tasks arrive."
  (when-let* ((buffer (get-buffer roost--compose-buffer)))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'roost-compose-mode)
                 (markerp roost--compose-body)
                 (not (equal (roost--compose-changing-summary (roost--compose-changing))
                             roost--compose-changing-shown)))
        (roost--compose-render)))))

(defun roost--in-order (choices)
  "A completion table of CHOICES that completion UIs show in their order.
Vertico, for one, sorts by length otherwise, which put \"Other
directory…\" above the projects you used last."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity) (cycle-sort-function . identity))
      (complete-with-action action choices string predicate))))

(defun roost--choose-from (prompt choices &optional default)
  "Choose from CHOICES, an alist of (LABEL . VALUE), with PROMPT.
A mouse click shows a menu at the pointer; the keyboard uses the minibuffer."
  (if (and (mouse-event-p last-nonmenu-event) (display-popup-menus-p))
      (x-popup-menu last-nonmenu-event (list prompt (cons "" choices)))
    (cdr (assoc (completing-read prompt (roost--in-order choices) nil t nil nil default) choices))))

(defun roost--ssh-config-hosts ()
  "The hosts ~/.ssh/config names, leaving out patterns.
A name may be quoted, as ssh allows, and one with a space is left out."
  (with-temp-buffer
    (ignore-errors (insert-file-contents "~/.ssh/config"))
    (let ((case-fold-search t) hosts)
      (while (re-search-forward "^[ \t]*Host\\(?:[ \t]*=[ \t]*\\|[ \t]+\\)\\([^#\n]*\\)" nil t)
        (let ((names (match-string 1)) (start 0))
          (while (string-match "\"\\([^\"]*\\)\"?\\|'\\([^']*\\)'?\\|[^ \t\"']+" names start)
            (let ((host (or (match-string 1 names) (match-string 2 names) (match-string 0 names))))
              (setq start (match-end 0))
              (unless (string-match-p "\\`\\'\\|[*?![:space:]]" host) (push host hosts))))))
      (delete-dups (nreverse hosts)))))

(defun roost--read-ssh-host ()
  "Read an SSH destination, completing from ~/.ssh/config.
Return (HOST), or nil when none was given."
  (let ((host (string-trim (completing-read "SSH host: " (roost--ssh-config-hosts)))))
    (cond ((string-empty-p host) nil)
          ;; Not a TRAMP path, nor an option to ssh.
          ((or (string-match-p "\\`-\\|[/:#|[:space:]]" host)
               (not (string-match-p "\\`\\(?:[^@]+@\\)?[^@]+\\'" host)))
           (user-error "Name an SSH host, such as dev or me@dev, or an alias from ~/.ssh/config"))
          (t (list host)))))

(defun roost--read-project-directory ()
  "Read a project checkout on a host you choose, or return nil.
The hosts are those Roost knows, starting on the draft's, then any other
SSH host; with only one known, it is that one.  The folder prompt starts
above the project used last on the host, or at its home."
  (let* ((hosts (roost--hosts))
         (current (when-let* ((directory (plist-get roost--compose-fields :directory)))
                    (ignore-errors (roost--directory-host directory))))
         ;; In a list, so that nil, from a menu clicked away from, is no host.
         (host (if (cdr hosts)
                   (roost--choose-from "Host: "
                                       (append (mapcar (lambda (host) (list (roost--host-label host) host))
                                                       hosts)
                                               (list (cons "Another SSH host…" 'another)))
                                       (roost--host-label (if (member current hosts) current (car hosts))))
                 (list (car hosts)))))
    (when (eq host 'another)
      (setq host (roost--read-ssh-host)))
    (when host
      (let* ((host (car host))
             (last (car (roost--host-projects host))))
        (read-directory-name (format "Project checkout on %s: " (roost--host-label host))
                             (roost--host-directory host (if last (file-name-directory last) "~"))
                             nil t)))))

(defun roost--back-in-draft (draft)
  "Make DRAFT, the buffer you asked something from, current again.
Say so if it has gone: a host can reply while you answer, and the draft
closes once its task is made."
  (unless (buffer-live-p draft)
    (user-error "The task's draft has closed"))
  (set-buffer draft))

(defun roost-compose-set-project ()
  "Choose the draft's project from known checkouts, or any directory.
The checkouts are those Roost has used, then those project.el knows.
\"Other directory…\" asks for a host, unless only one is known, and
then for a folder there, starting above the project used last on it."
  (interactive)
  (let* ((draft (current-buffer))
         (projects (mapcar (lambda (dir) (cons (roost--project-label dir) dir))
                           (roost--project-choices)))
         ;; Under the project used last, which RET still takes, and on
         ;; screen however many projects there are.
         (choices (append (seq-take projects 1) (list (cons "Other directory…" 'other))
                          (seq-drop projects 1)))
         (choice (roost--choose-from "Project: " choices)))
    (roost--back-in-draft draft)
    (when (eq choice 'other)
      (setq choice (roost--read-project-directory))
      (roost--back-in-draft draft))
    (when choice
      (roost--compose-move (file-name-as-directory (expand-file-name choice)))
      (roost--compose-render))))

(defun roost--compose-tied ()
  "What ties the draft to its project, as words, or nil.
It says nothing of the project otherwise, and can go to another."
  (cond ((roost--compose-quoted-files) "it quotes that project's files")
        ((plist-get roost--compose-fields :source) "it forks a task there")
        ((plist-get roost--compose-fields :issue) "it starts from an issue there")
        ((plist-get roost--compose-fields :parent) "a task there offered it")))

(defun roost--compose-move (directory)
  "Make DIRECTORY the draft's project.
Moved elsewhere, a draft of an offer is a task of its own, under none."
  (let ((base (plist-get roost--compose-fields :base))
        (here (plist-get roost--compose-fields :directory)))
    ;; The starting ref now names a ref of this project, not the task's.
    (setq roost--compose-fields
          (thread-first roost--compose-fields
                        (plist-put :directory directory)
                        (plist-put :integration (and base (roost--compose-integration directory base)))
                        (plist-put :source nil)))
    (unless (and here (equal (roost--project-place here) (roost--project-place directory)))
      (setq roost--compose-fields (plist-put (plist-put roost--compose-fields :parent nil) :offer nil)))))

(defun roost-compose-set-agent ()
  "Choose the draft's agent."
  (interactive)
  (when-let* ((draft (current-buffer))
              (agent (roost--choose-from "Agent: " (mapcar (lambda (agent) (cons agent agent))
                                                           roost--agents)
                                         roost-default-agent)))
    (roost--back-in-draft draft)
    (setq roost--compose-fields (plist-put roost--compose-fields :agent agent))
    (roost--compose-render)))

(defun roost--compose-continues (&optional agent)
  "The ID of the task whose conversation the draft goes on with, or nil.
That is a fork's, unless you chose a new conversation or another agent.
With AGENT, whether an attempt of the draft's by AGENT goes on with it."
  (let ((fields roost--compose-fields))
    (and (plist-get fields :source)
         (plist-get fields :conversation)
         (equal (or agent (plist-get fields :agent)) (plist-get fields :source-agent))
         (plist-get fields :source-id))))

(defun roost-compose-set-conversation ()
  "Choose whether a fork goes on with its task's conversation or starts a new one.
Going on, its agent starts from a copy of the task's conversation, in a
worktree with the task's uncommitted changes as well as its commits, and
the task's own conversation goes on as before."
  (interactive)
  (let ((fields roost--compose-fields))
    (unless (plist-get fields :source)
      (user-error "Only a fork of a task goes on with its conversation: %s on the task drafts one"
                  (substitute-command-keys "\\[universal-argument] \\[roost-new-task]")))
    (cond ((roost--compose-continues)
           (setq roost--compose-fields (plist-put fields :conversation nil)))
          ((not (when-let* ((task (gethash (list (roost--directory-host (plist-get fields :directory))
                                                 (plist-get fields :source-id))
                                           roost--tasks)))
                  (or (roost--field task 'agentSession) (roost--field task 'claudeSession))))
           (user-error "%s's agent hasn't started a conversation yet" (plist-get fields :source)))
          (t
           ;; Its agent's conversation, so that agent.
           (setq roost--compose-fields
                 (thread-first fields
                               (plist-put :conversation t)
                               (plist-put :agent (plist-get fields :source-agent))))))
    (roost--compose-render)))

(defun roost--compose-integration (directory ref)
  "The branch a task in DIRECTORY started at REF merges into.
As the helper decides it, or nil for the primary checkout's."
  (let ((full (string-trim (or (roost--git-in directory "rev-parse" "--symbolic-full-name" ref) ""))))
    (cond ((string-prefix-p "refs/heads/" full)
           (let* ((branch (substring full (length "refs/heads/")))
                  (host (roost--directory-host directory))
                  ;; The primary checkout, which the helper records as the repo.
                  (repo (when-let* ((list (roost--git-in directory "worktree" "list" "--porcelain")))
                          (string-remove-prefix "worktree " (car (split-string list "\n")))))
                  (source (seq-find (lambda (task)
                                      (and (equal (roost--field task 'host) host)
                                           (equal (roost--field task 'repo) repo)
                                           (equal (roost--field task 'branch) branch)))
                                    (roost-tasks))))
             ;; Empty when that task started with the primary checkout detached.
             (if source (roost--field source 'integrationBranch) branch)))
          ((string-prefix-p "refs/remotes/" full)
           ;; Remote names may hold slashes, so take the longest that fits.
           (let* ((remotes (split-string (or (roost--git-in directory "remote") "") "\n" t))
                  (remote (car (sort (seq-filter (lambda (remote)
                                                   (string-prefix-p (concat "refs/remotes/" remote "/") full))
                                                 remotes)
                                     (lambda (a b) (> (length a) (length b))))))
                  (branch (and remote (substring full (length (concat "refs/remotes/" remote "/"))))))
             (unless (member branch '(nil "HEAD")) branch))))))

(defun roost-compose-set-base ()
  "Choose the draft's starting Git ref; empty means the primary branch.
A branch is also the one the task merges into."
  (interactive)
  (let* ((draft (current-buffer))
         (directory (plist-get roost--compose-fields :directory))
         ;; Git runs on the project's host.
         (refs (when directory
                 (split-string (or (roost--git-in directory "for-each-ref" "--format=%(refname:short)"
                                                  "refs/heads" "refs/remotes")
                                   "")
                               "\n" t)))
         (ref (string-trim (completing-read "Start from ref (empty = primary checkout's branch): "
                                            (cons "HEAD" refs) nil nil)))
         (base (unless (string-empty-p ref) ref)))
    (roost--back-in-draft draft)
    (setq roost--compose-fields
          (thread-first roost--compose-fields
                        (plist-put :base base)
                        (plist-put :integration (and base directory
                                                     (roost--compose-integration directory ref)))
                        (plist-put :source nil)))
    (roost--compose-render)))

(defun roost-compose-set-name ()
  "Name the draft; empty derives the name from the prompt."
  (interactive)
  (let* ((draft (current-buffer))
         (name (string-trim (read-string "Task name (empty = from the prompt): "
                                         (plist-get roost--compose-fields :name)))))
    (roost--back-in-draft draft)
    (setq roost--compose-fields
          (plist-put roost--compose-fields :name (unless (string-empty-p name) name)))
    (roost--compose-render)))

(defconst roost--attempts-most 5
  "The most tasks a draft makes from its prompt, which is as many as a host takes.")

(defun roost--compose-agents ()
  "The agent of each task the draft makes, in order.
One, the draft's, unless it makes several attempts at its prompt."
  (let ((agent (plist-get roost--compose-fields :agent))
        (attempts (plist-get roost--compose-fields :attempts)))
    (if (integerp attempts)
        (make-list attempts agent)
      (cons agent attempts))))

(defun roost-compose-set-attempts ()
  "Choose how many tasks the draft makes from its prompt, for you to compare.
A number from 1 to 5 makes that many, each by the draft's agent.  Agents'
names with spaces between, as \"claude codex\", make one by each, in
that order; the first becomes the draft's agent.  Empty, or 1, makes one
task.  The first task has the draft's name and the others that name with
2, 3 and so on after it; `roost-compare-attempts' shows what each changed."
  (interactive)
  (let* ((draft (current-buffer))
         (attempts (plist-get roost--compose-fields :attempts))
         (said (string-trim
                (read-string (format "Attempts (1 to %d, or an agent for each, as \"claude codex\"; empty = 1): "
                                     roost--attempts-most)
                             (cond ((integerp attempts) (number-to-string attempts))
                                   (attempts (string-join (roost--compose-agents) " "))))))
         (named (split-string said "[ \t,]+" t))
         (unknown (seq-find (lambda (agent) (not (member agent roost--agents))) named)))
    (roost--back-in-draft draft)
    (cond ((string-match-p "\\`[0-9]*\\'" said)
           (let ((count (if (string-empty-p said) 1 (string-to-number said))))
             (unless (<= 1 count roost--attempts-most)
               (user-error "A draft makes from 1 to %d attempts" roost--attempts-most))
             (setq roost--compose-fields
                   (plist-put roost--compose-fields :attempts (when (> count 1) count)))))
          (unknown
           (user-error "Roost has no agent named %s: give a number, or some of %s"
                       unknown (string-join roost--agents ", ")))
          ((length> named roost--attempts-most)
           (user-error "A draft makes from 1 to %d attempts" roost--attempts-most))
          (t
           (setq roost--compose-fields
                 (thread-first roost--compose-fields
                               (plist-put :agent (car named))
                               (plist-put :attempts (cdr named))))))
    (roost--compose-render)))

(defun roost--issue-label (issue)
  "What names ISSUE: #12 for GitHub's or GitLab's, its key for a Jira work item."
  (or (alist-get 'key issue) (format "#%s" (alist-get 'number issue))))

(defun roost--issue-prompt (issue)
  "Prompt text for ISSUE, GitHub's, GitLab's or Jira's.
Its title, its text, then where it is."
  (let ((body (string-trim (or (alist-get 'body issue) "")))
        (url (alist-get 'url issue)))
    (concat (alist-get 'title issue) "\n\n"
            (if (string-empty-p body) "" (concat body "\n\n"))
            (if-let* ((key (alist-get 'key issue)))
                (format "This is Jira issue %s%s" key (if url (concat ": " url) "."))
              (format "This is %s issue #%s: %s" (roost--forge-name issue) (alist-get 'number issue) url)))))

(defun roost--jira-issue-whole (issue draft)
  "ISSUE, a Jira work item as listed, with all its text, as twg reads it.
A list has only its description, and a site can keep the text in a
rich-text field of its own.  ISSUE stays as it is if twg finds no text,
or can't read it, which a message says.  DRAFT, the buffer that asked,
is current again after."
  (let* ((key (alist-get 'key issue))
         (whole (condition-case err
                    (progn (message "Roost: reading %s…" key)
                           ;; twg's sign-in is yours, here, as for the list.
                           (prog1 (roost--request-wait nil "jira-issue" (list (cons 'key key)))
                             (message nil)))
                  (user-error
                   (message "Roost: couldn't read all of %s's text: %s"
                            key (car (split-string (error-message-string err) "\n")))
                   nil)))
         (body (alist-get 'body whole)))
    (roost--back-in-draft draft)
    (if (string-empty-p (or body "")) issue (cons (cons 'body body) issue))))

(defun roost-compose-set-issue ()
  "Start the draft from one of the project's open issues.
The issue's title and text become the prompt, unless one is already
written.  GitHub's or GitLab's, as the project's origin is on, are
listed with gh or glab on the project's host, and the task's pull
request will close the one you choose.  With twg,
Atlassian's Teamwork Graph CLI, signed in on this machine, the Jira
work items `roost-jira-query' finds are listed too, and the task's
branch leads with the key of the one you choose.  A work item's text
is its description and its site's rich-text fields, read as you choose it."
  (interactive)
  (let* ((draft (current-buffer))
         (directory (or (plist-get roost--compose-fields :directory)
                        (user-error "Choose a project first (%s)"
                                    (substitute-command-keys "\\[roost-compose-set-project]"))))
         (host (roost--directory-host directory))
         (jql (roost--project-value directory 'roost-jira-query))
         (outcomes (progn (message "Roost: listing open issues on %s…" (roost--host-label host))
                          (prog1 (roost--requests-wait
                                  (cons (list host "issues" (list (cons 'directory (file-local-name directory))))
                                        ;; twg's sign-in is yours, here, wherever the project is.
                                        (when jql (list (list nil "jira-issues" (list (cons 'jql jql)))))))
                            (roost--back-in-draft draft))))
         (forge (car outcomes))
         ;; nil when twg isn't installed.
         (jira (cadr outcomes))
         (issues (append (and (car forge) (cdr forge))
                         (and (car jira) (alist-get 'issues (cdr jira)))
                         nil))
         (none "No issue")
         (choices (mapcar (lambda (issue)
                            (cons (format "%s %s" (roost--issue-label issue) (alist-get 'title issue))
                                  issue))
                          issues))
         (choices (if (plist-get roost--compose-fields :issue) (cons (cons none nil) choices) choices))
         (completion-extra-properties
          (list :annotation-function
                (lambda (choice)
                  (when-let* ((issue (cdr (assoc choice choices)))
                              (words (append (ensure-list (alist-get 'status issue))
                                             (alist-get 'labels issue) nil)))
                    (concat "  " (propertize (string-join words ", ") 'face 'roost-dim)))))))
    (unless issues
      (user-error "%s" (string-join
                        (delq nil (list (if (car forge)
                                            (format "%s has no open issues" (roost--project-label directory))
                                          (cdr forge))
                                        (pcase jira
                                          (`(nil . ,err) (concat "Jira: " err))
                                          (`(t . ,(pred identity))
                                           "no Jira work items match `roost-jira-query'"))))
                        "; ")))
    (let* ((issue (cdr (assoc (completing-read
                               (pcase jira
                                 (`(nil . ,err)
                                  (format "Issue (Jira: %s): "
                                          (truncate-string-to-width (car (split-string err "\n")) 60 nil nil "…")))
                                 (_ "Issue: "))
                               (roost--in-order choices) nil t)
                              choices)))
           (_ (roost--back-in-draft draft))
           (issue (if (alist-get 'key issue) (roost--jira-issue-whole issue draft) issue))
           ;; The prompt the last issue gave, text and all, which the
           ;; task's record leaves out.
           (previous (plist-get roost--compose-fields :issue-prompt))
           (prompt (roost--compose-prompt)))
      (setq roost--compose-fields (plist-put roost--compose-fields :issue
                                             (when issue
                                               (delq nil (list (assq 'number issue) (assq 'key issue)
                                                               (assq 'title issue) (assq 'url issue))))))
      ;; An untouched prompt follows the issue; a written one gains it below.
      (when issue
        (let ((inhibit-read-only t)
              (untouched (or (string-empty-p prompt) (equal prompt previous)))
              (text (roost--issue-prompt issue)))
          (setq roost--compose-fields (plist-put roost--compose-fields :issue-prompt (string-trim text)))
          (save-excursion
            (if untouched
                (delete-region roost--compose-body (point-max))
              (goto-char (point-max))
              (insert "\n\n"))
            (goto-char (point-max))
            (insert text))))
      (roost--compose-render))))

(defun roost--draft-clicked (event mode)
  "Select the window whose draft, in MODE, EVENT clicked a button of, if it did.
Only a click in a header line, where the buttons are: an earlier click
left in `last-nonmenu-event' doesn't choose the draft."
  (when (and (mouse-event-p event) (eq (posn-area (event-start event)) 'header-line))
    (let ((window (posn-window (event-start event))))
      (when (and (window-live-p window)
                 (eq (buffer-local-value 'major-mode (window-buffer window)) mode))
        (select-window window)))))

(defun roost--quit-questions-here (function)
  "Quit the questions you left open in the minibuffer, then call FUNCTION here.
Here is the buffer that is current, such as the draft or panel whose
button you clicked, shown again, as quitting gives back the windows the
question found.  A question left open would take one FUNCTION asks, or
hold back the task it opens.  Return nil when there are none; otherwise
this doesn't return, as for `roost--quit-questions-left-open'."
  (let ((buffer (current-buffer)))
    (roost--quit-questions-left-open
     (lambda ()
       (when (buffer-live-p buffer)
         (pop-to-buffer buffer)
         (funcall function))))))

(defun roost-compose-cancel (&optional event)
  "Discard the draft, or the one whose Cancel button EVENT clicked."
  (interactive (list last-nonmenu-event))
  (roost--draft-clicked event 'roost-compose-mode)
  ;; One of the draft's own, as for its name, would outlive it.
  (roost--quit-questions-here #'roost-compose-cancel)
  (when (or (string-empty-p (roost--compose-prompt))
            (yes-or-no-p "Discard this task draft? "))
    (quit-window t)))

(defun roost-compose-submit (&optional event)
  "Create the drafted task.  The draft is kept if creation fails.
EVENT, a click on the draft's Create button, says which draft.
A draft that makes several attempts creates a task for each, from the
same prompt, project and starting point: the first is the draft's own,
which opens, and the others have its name with 2, 3 and so on after it.
One of the others that fails says so, and the draft goes on."
  (interactive (list last-nonmenu-event))
  (roost--draft-clicked event 'roost-compose-mode)
  (let ((fields roost--compose-fields)
        (prompt (roost--compose-prompt))
        (name (roost--compose-name))
        (buffer (current-buffer)))
    (unless (plist-get fields :directory)
      (user-error "Choose a project first (%s)" (substitute-command-keys "\\[roost-compose-set-project]")))
    (when (string-empty-p name)
      (user-error "Write a prompt, or name the task (%s)" (substitute-command-keys "\\[roost-compose-set-name]")))
    (when roost--compose-submitting
      (user-error "Already creating %s" name))
    ;; The project's setup command can be asked about.
    (roost--quit-questions-here #'roost-compose-submit)
    (let* ((directory (plist-get fields :directory))
           (host (roost--directory-host directory))
           (what (roost--compose-what))
           (asked (copy-sequence roost--compose-asked))
           ;; Asked again in the same project, as after no reply came, the
           ;; host answers with the task it made, if it did, from what it
           ;; was asked for first, or since.
           (first (progn (if (not (equal (car roost--compose-asked) directory))
                             (setq roost--compose-asked (list directory (roost--random-id) what))
                           (unless (equal (nth 2 roost--compose-asked) what)
                             (setcar (nthcdr 2 roost--compose-asked) nil)))
                         (nth 2 roost--compose-asked)))
           (group (cadr roost--compose-asked))
           ;; The agent of each attempt after the first, for a draft that
           ;; makes several.
           (others (cdr (roost--compose-agents)))
           (total (1+ (length others)))
           (sent nil)
           ;; The project's setup command is read for each, and asked about once.
           (roost--project-values (list t)))
      (setq roost--compose-submitting t
            roost--draft-note (if others
                                  (format " Creating %s and %d more…" name (length others))
                                (format " Creating %s…" name)))
      (condition-case err
          (progn
            ;; The attempts after the first, asked for with it rather than
            ;; once it is made.  Each has an ID made from the draft's, the
            ;; same however often the draft asks, so its host makes each
            ;; once.  They go first: the draft's own task is the one that
            ;; opens, and what is asked for last is what opens.
            (seq-do-indexed
             (lambda (agent index)
               (let ((n (+ index 2)))
                 (roost--create-task
                  directory (format "%s %d" name n) (plist-get fields :base) prompt agent
                  ;; You stay where you are.
                  (lambda (&rest _) t)
                  nil
                  `((createId . ,(format "%s%02x" group n))
                    ,@(roost--attempt-field group n total)
                    ,@(when-let* ((source (roost--compose-continues agent)))
                        (list (cons 'forkFrom source)))
                    ,@(when-let* ((issue (plist-get fields :issue)))
                        (list (cons 'issue issue)))
                    ,@(when-let* ((parent (plist-get fields :parent)))
                        (list (cons 'parent (cadr parent))))))
                 (setq sent t)))
             others)
            (roost--create-task
             (plist-get fields :directory) name (plist-get fields :base) prompt
             (plist-get fields :agent)
             (lambda (task &optional found)
               (or (roost--compose-made buffer fields task (if found first what) t)
                   ;; One an agent offered leaves you where you are, as the
                   ;; offer came while you were busy there.
                   (and (plist-get fields :parent) t)))
             (lambda (err)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq roost--compose-submitting nil)
                   (if (not (get-text-property 0 'roost-no-reply err))
                       (roost--draft-error "Could not create the task" err 'roost-compose-submit)
                     ;; It may yet be made: then a poll of its host lists it.
                     (roost--remember-host host)
                     (roost-watch-mode 1)
                     (setq roost--draft-note
                           (format " No reply from %s after %s; the task opens here if it was made · %s asks again"
                                   (roost--host-label host)
                                   (let ((seconds (+ roost-request-timeout roost--create-seconds)))
                                     (if (< seconds 60) (format "%ds" seconds) (format "%dm" (/ seconds 60))))
                                   (substitute-command-keys "\\[roost-compose-submit]")))
                     (message "Roost: no reply from %s about %s yet; it opens if it was made"
                              (roost--host-label host) name)))))
             `((createId . ,(cadr roost--compose-asked))
               ,@(roost--attempt-field group 1 total)
               ,@(when-let* ((source (roost--compose-continues)))
                   (list (cons 'forkFrom source)))
               ,@(when-let* ((issue (plist-get fields :issue)))
                   (list (cons 'issue issue)))
               ,@(when-let* ((parent (plist-get fields :parent)))
                   (list (cons 'parent (cadr parent))))
               ,@(when-let* (((plist-get fields :parent))
                             (offer (plist-get fields :offer)))
                   (list (cons 'offer offer)))))
            (when others
              (message "Roost: creating %s and %d more from its prompt…" name (length others))))
        ;; Nothing reached the host, as when you quit the question about
        ;; the project's setup command: the draft is ready to create again.
        ((quit error)
         (setq roost--compose-submitting nil
               roost--draft-note nil)
         ;; Nor was it asked for what it says now; unless an attempt went,
         ;; which asking again must name as it was.
         (unless sent
           (setq roost--compose-asked asked))
         (signal (car err) (cdr err)))))))

(defun roost--attempt-field (group n total)
  "What a request to create attempt N of TOTAL at one prompt says of it.
GROUP, the creation ID of the draft that asks, is what its attempts
share.  Nothing for a draft that makes one task."
  (when (> total 1)
    `((attempt (group . ,group) (n . ,n) (of . ,total)))))

(defun roost--compose-what ()
  "What the draft asks for, to tell whether it says that still.
All of it, though you have narrowed it to some, and the task it would
show under, which moving it elsewhere and back takes away."
  (save-restriction
    (widen)
    (list (roost--compose-prompt)
          (mapcar (lambda (field) (plist-get roost--compose-fields field))
                  '(:directory :agent :base :name :issue :parent :attempts)))))

(defun roost--compose-made (buffer fields task what &optional own)
  "Close BUFFER, the draft with FIELDS, as its host made TASK from WHAT.
WHAT is as `roost--compose-what' gives it, or nil if not known.  OWN
says this is the reply to the draft's request, not a poll's news of an
earlier one.  An Org entry it was drafted from links to TASK, if it can.
A draft that says something else now is yours, as when you wrote on
after asking, or changed it after no reply: it stays, saying what was
made, and this returns non-nil."
  (when-let* ((marker (plist-get fields :org)))
    (condition-case err
        (roost--org-link marker task)
      (error (message "Roost could not record %s in its Org entry: %s"
                      (roost--field task 'name) (error-message-string err)))))
  (if (not (and (buffer-live-p buffer)
                (with-current-buffer buffer (not (equal (roost--compose-what) what)))))
      (progn (roost--close-buffer buffer) nil)
    (with-current-buffer buffer
      (setq roost--compose-fields (plist-put roost--compose-fields :org nil))
      ;; Unless a request of its own is out, as you asked again since the
      ;; poll that found this: it says what it made in its own time.
      (unless (and roost--compose-submitting (not own))
        ;; Whatever you ask for from here on is another task.
        (setq roost--compose-submitting nil
              roost--compose-asked nil
              roost--draft-note
              (format " Made %s from what you sent before; this draft is as you left it · %s makes another task"
                      (roost--field task 'name)
                      (substitute-command-keys "\\[roost-compose-submit]"))))
      (force-mode-line-update))
    t))

(defun roost--compose-listed (host tasks)
  "Close the draft of the task TASKS, which HOST listed, hold, and open it.
That is once the draft's request got no reply in time, and the host
made the task anyway.  It opens where the draft is, if you are there."
  (when-let* ((buffer (get-buffer roost--compose-buffer))
              ((not (buffer-local-value 'roost--compose-submitting buffer)))
              (asked (buffer-local-value 'roost--compose-asked buffer))
              ((equal (roost--directory-host (car asked)) host))
              (made (seq-find (lambda (task) (equal (roost--field task 'createId) (cadr asked))) tasks))
              (task (gethash (list host (roost--field made 'id)) roost--tasks)))
    (let ((fields (buffer-local-value 'roost--compose-fields buffer))
          (generation roost--open-generation))
      (roost--task-made host task (roost--field task 'name)
                        (lambda (task &rest _)
                          (or (roost--compose-made buffer fields task (nth 2 asked))
                              ;; One an agent offered leaves you where you are.
                              (and (plist-get fields :parent) t)))
                        (lambda ()
                          (and (= generation roost--open-generation)
                               (eq (window-buffer (roost--window-you-are-in)) buffer)))))))

;;;; Task commands

(defun roost--release-terminal (task)
  "Disconnect the terminal showing TASK's own tmux session.
Return its buffers.  A task's own session holds only its agent's
window, so stopping, resuming, retiring or forgetting the task ends the
session, and its terminal would then report a lost connection.  Opening
the task again connects anew.  A session shared by tasks from before
Roost gave each task one outlives the task."
  (let ((host (roost--field task 'host))
        (socket (roost--field task 'socket))
        (session (roost--field task 'session))
        (id (roost--field task 'id)))
    (when-let* (((fboundp 'tmux-control-disconnect))
                ((fboundp 'tmux-control-buffer-session))
                ((stringp session))
                ((stringp id))
                ((string-suffix-p (concat "-" (substring id 0 (min 6 (length id)))) session))
                (terminals (seq-filter (lambda (buffer)
                                         (with-current-buffer buffer
                                           (and (equal (tmux-control-buffer-session) session)
                                                (equal (tmux-control-buffer-host) host)
                                                (equal (tmux-control-buffer-socket-name) socket))))
                                       (buffer-list))))
      ;; Through the buffer holding the connection: a scrollback view of
      ;; it, say, holds none of its own.
      (when-let* ((connection (seq-find #'get-buffer-process terminals)))
        (with-current-buffer connection
          (tmux-control-disconnect)))
      terminals)))

(defun roost--restore-terminal (task terminals)
  "Reconnect TERMINALS, released for an action on TASK the host refused.
Only where one is still shown, and once the host confirms that TASK's
window is still there: reconnecting to an ended session would start an
empty one.  Opening the task reconnects the rest."
  (when (and terminals (fboundp 'tmux-control-reconnect))
    (roost--request (roost--field task 'host) "inspect" (list (cons 'id (roost--field task 'id)))
                    (lambda (_)
                      (when-let* ((window (seq-find (lambda (window)
                                                      (memq (window-buffer window) terminals))
                                                    (window-list-1 nil 'nomini t))))
                        (with-selected-window window
                          (tmux-control-reconnect))))
                    #'ignore)))

(defun roost--discard-terminal (terminals)
  "Kill TERMINALS, whose session ended, rather than leave them blank.
The windows showing them go back to what they showed before, but not to
another task's terminal: nobody asked for that task."
  (roost--when-out-of-minibuffer
   (lambda ()
     (let ((kill-buffer-query-functions nil)
           (switch-to-prev-buffer-skip
            (lambda (_window buffer _bury-or-kill) (roost--terminal-task buffer))))
       (dolist (buffer terminals)
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))))))

(defconst roost--action-messages
  '(("send" . "Sent to %s") ("stop" . "Stopped %s") ("resume" . "Resumed %s")
    ("shell" . "Opened a shell in %s's worktree"))
  "What `roost--act' says once each action is done, for a task's name.
The other actions say more themselves when they finish.")

(defun roost--act (task action &optional parameters callback failure replied)
  "Run ACTION on TASK with PARAMETERS, then CALLBACK with the updated task.
FAILURE, if given, receives the error message instead of Roost reporting it.
REPLIED, if given, is called as the host replies well, before the
terminal the action ended closes."
  (let* ((host (roost--field task 'host))
         (listed (gethash (roost--key task) roost--tasks))
         ;; What removes the worktree runs the project's teardown first.
         (teardown (when (and (member action '("retire" "merge" "discard"))
                              (roost--field task 'repo))
                     (roost--project-value (roost--project-directory task) 'roost-teardown-command)))
         ;; The host refuses to resume an agent still running, whose
         ;; terminal stays.
         (terminals (when (or (member action '("stop" "retire" "merge" "forget" "discard"))
                              (and (equal action "resume") (not (roost--field task 'live))))
                      (roost--release-terminal task))))
    (apply #'roost--request host action (append (list (cons 'id (roost--field task 'id)))
                                                (when teardown (list (cons 'teardown teardown)))
                                                parameters)
           (lambda (updated)
             (when replied (funcall replied))
             (roost--discard-terminal terminals)
             (cl-incf (gethash host roost--revisions 0))
             ;; `pushed' is transient: the callback sees it, the cache does not.
             ;; So is `note', what there is to say of a change of branch.
             (let ((pushed (assq 'pushed updated))
                   (note (assq 'note updated))
                   (already (alist-get 'alreadySent updated))
                   (torn (alist-get 'teardownFailure updated))
                   (output (alist-get 'teardownOutput updated))
                   ;; Forgetting says so itself, and always leaves things.
                   (left (unless (equal action "forget") (alist-get 'leftBehind updated))))
               (setq updated (roost--cache-reply host updated listed))
               (roost--redraw)
               (when-let* ((said (cdr (assoc action roost--action-messages))))
                 (message (if already "Already sent to %s" said) (roost--field task 'name)))
               (when callback
                 (funcall callback (append (delq nil (list pushed note)) updated)))
               (when left
                 (message "%s" (string-join (delq nil (list (current-message)
                                                            (concat "left in place: " (string-join left ", "))))
                                            "; ")))
               (when torn
                 (display-warning
                  'roost (format "%s's teardown command %s; Roost removed its worktree anyway%s"
                                 (roost--field task 'name) torn
                                 (if (member output '(nil "")) "." (concat ":\n\n" output)))))))
           (lambda (err)
             ;; Refused, as retiring unmerged work is: the agent runs on,
             ;; or, refused a resume, one you started by hand in its session.
             (when (or (roost--field task 'live) (equal action "resume"))
               (roost--restore-terminal task terminals))
             (if failure
                 (funcall failure err)
               (message "Roost %s: %s" (roost--host-label host) err)))
           (when teardown (list (+ roost-request-timeout roost--teardown-seconds))))))

(defvar roost--resuming nil
  "Keys of the tasks that resuming several at once has yet to resume.")

;;;###autoload
(defun roost-resume (&optional task offer)
  "Restart TASK, resuming its recorded agent conversation.
With OFFER, as when you give the command, and other agents on TASK's
host crashed with TASK's, as when the host restarted, ask whether to
resume those too."
  (interactive (list nil t))
  (setq task (roost--choose task))
  (let ((others (and offer (roost--crashed-with task)))
        (host (roost--host-label (roost--field task 'host))))
    (if (and others
             (y-or-n-p (if (cdr others)
                           (format "Resume the %d other agents that crashed on %s too? " (length others) host)
                         (format "Resume the other agent that crashed on %s too? " host))))
        (roost--resume-together task others)
      ;; Now, rather than in its turn among several resuming.
      (setq roost--resuming (delete (roost--key task) roost--resuming))
      (let* ((listed (gethash (roost--key task) roost--tasks))
             (stayed (roost--you-stay))
             (generation roost--open-generation)
             there)
        (roost--act task "resume" (roost--resume-parameters task)
                    (lambda (updated)
                      (when there
                        ;; After its old terminal, which waits for that too.
                        (roost--open-once-out generation (roost--key updated) listed
                                              (lambda () (when there (roost-open-task updated))))))
                    nil
                    (lambda () (roost--stayed-as-it-goes stayed (lambda (still) (setq there still)))))))))

(defun roost--resume-parameters (task)
  "What a request to resume TASK says besides which task."
  `((programStatus . ,(if roost-program-status t :false))
    (size . ,(roost--terminal-size task))))

(defun roost--crashed-with (task)
  "The other tasks on TASK's host whose agents crashed, if TASK's did.
Each crashed, as every agent there does when the host restarts or its
tmux server ends, and can resume.  Those stopped, exited or failed are
left out: you or the agent ended them.  So are those that resuming
several will resume, which you were asked about already, and all of
them while TASK is one of those."
  (when (and (equal (roost--field task 'status) "crashed")
             (not (member (roost--key task) roost--resuming)))
    (let ((host (roost--field task 'host))
          (key (roost--key task)))
      (seq-filter (lambda (other)
                    (and (equal (roost--field other 'host) host)
                         (not (equal (roost--key other) key))
                         (equal (roost--field other 'status) "crashed")
                         (not (member (roost--key other) roost--resuming))
                         (roost--action-applies-p other #'roost-resume)))
                  (roost-tasks)))))

(defun roost--resume-together (task others)
  "Resume TASK, then open it, and resume OTHERS, one after another.
OTHERS' terminals stay closed.  Once all have replied, say how many
resumed, naming each that didn't and why: one that fails doesn't stop
the rest.  One you resumed, stopped or forgot meanwhile, or that no
longer shows as crashed, is passed over."
  (let* ((host (roost--field task 'host))
         (listed (gethash (roost--key task) roost--tasks))
         (stayed (roost--you-stay))
         (generation roost--open-generation)
         (tried 1)
         there failures said)
    ;; Until each replies, opening one of them offers the rest no more.
    (setq roost--resuming (append (mapcar #'roost--key (cons task others)) roost--resuming))
    ;; A quit as the first asks gets no reply, and the rest aren't asked.
    (condition-case err
    (cl-labels ((replied (task)
                  (setq roost--resuming (delete (roost--key task) roost--resuming)))
                (next (rest)
                  (if (null rest)
                      (message "%s" (setq said (roost--resumed-message host tried (reverse failures))))
                    (let* ((key (roost--key (car rest)))
                           (other (gethash key roost--tasks)))
                      ;; Unless, since you were asked, you resumed it,
                      ;; stopped or forgot it, or it ended another way.
                      (if (not (and other (member key roost--resuming)
                                    (equal (roost--field other 'status) "crashed")
                                    (roost--action-applies-p other #'roost-resume)))
                          (progn (replied (car rest)) (next (cdr rest)))
                        (cl-incf tried)
                        (roost--act other "resume" (roost--resume-parameters other)
                                    (lambda (_)
                                      (replied other)
                                      (next (cdr rest)))
                                    (lambda (err)
                                      (replied other)
                                      (push (cons other err) failures)
                                      (next (cdr rest)))))))))
      (roost--act task "resume" (roost--resume-parameters task)
                  (lambda (updated)
                    (replied task)
                    ;; The others first: an error opening this one mustn't
                    ;; stop them.
                    (next others)
                    ;; Said again once its terminal shows, if done by then:
                    ;; opening clears the echo area.
                    (when there
                      (roost--open-once-out generation (roost--key updated) listed
                                            (lambda ()
                                              (when there (roost-open-task updated nil (lambda (_) said)))))))
                  (lambda (err)
                    (replied task)
                    (push (cons task err) failures)
                    (next others))
                  (lambda () (roost--stayed-as-it-goes stayed (lambda (still) (setq there still))))))
      (quit (dolist (one (cons task others))
              (setq roost--resuming (delete (roost--key one) roost--resuming)))
            (signal (car err) (cdr err))))))

(defun roost--resumed-message (host total failures)
  "What resuming TOTAL agents on HOST did, with FAILURES, each (TASK . ERROR)."
  (let ((label (roost--host-label host))
        (resumed (- total (length failures))))
    (concat (cond ((null failures)
                   (format "Resumed %d agent%s on %s" total (if (= total 1) "" "s") label))
                  ((zerop resumed)
                   (if (= total 1)
                       (format "Resumed no agent on %s" label)
                     (format "Resumed none of the %d agents on %s" total label)))
                  (t (format "Resumed %d of %d agents on %s" resumed total label)))
            (mapconcat (lambda (failure)
                         (format "; %s didn't resume: %s" (roost--field (car failure) 'name) (cdr failure)))
                       failures ""))))

;;;###autoload
(defun roost-send (&optional task text)
  "Send TEXT as a literal pasted prompt to TASK's agent pane.
Interactively, write the prompt in a draft buffer, which holds your
review notes for the agent (see `roost-note'); \\<roost-send-mode-map>\\[roost-send-submit] sends it.
While Roost last saw a startup or permission prompt, ask first: the
paste could answer that menu, but agents report no event when a
permission is declined in the terminal.  TEXT holding a control
character, other than a line or page break or a tab, is refused: the
agent's terminal would take it as a key."
  (interactive)
  (setq task (roost--choose task))
  (if (and (not text) (called-interactively-p 'any))
      (roost--send-draft task)
    (roost--send-text task (or text (read-string (format "Send to %s: " (roost--field task 'name)))))))

(defun roost--send-text (task text &optional callback failure look id)
  "Send TEXT to TASK's agent, confirming first if it may be at a prompt.
CALLBACK and FAILURE are passed to `roost--act'.  With LOOK, as for
your notes, its host first records where the task stands as where you
last looked at it.  With ID, its host pastes TEXT once for that ID, as
when you ask again after no reply."
  (let* ((problem (roost--text-problem text))
         (status (roost--field task 'status))
         (force (when (and (not problem) (member status '("starting" "permission")))
                  (or (yes-or-no-p
                       (format "Roost last saw %s %s; send anyway, if you have answered it in the terminal? "
                               (roost--field task 'name)
                               (if (equal status "starting") "starting up" "asking for permission")))
                      (user-error "Open the task with RET to answer it")))))
    (cond ((not problem)
           (roost--act task "send" (append (list (cons 'text text))
                                           (when force (list (cons 'force t)))
                                           (when look (list (cons 'look t)))
                                           (when id (list (cons 'sendId id))))
                       callback failure))
          (failure (funcall failure problem))
          (t (user-error "%s" problem)))))

;;;; Composing a follow-up

(defvar-local roost--send-task nil
  "The task a follow-up draft will be sent to.")
(defvar-local roost--send-sending nil
  "Non-nil while the drafted follow-up is being sent.")
(defvar-local roost--send-notes nil
  "Identifiers of the review notes in this draft.
Sending it clears those it holds as they are.")
(defvar-local roost--send-asked nil
  "The text this draft last asked to send and the ID it asked with, a cons.
The ID is the same each time for the same text, so its host pastes it
once, however often you ask: it answers again that it did.")

(defvar-keymap roost-send-mode-map
  :doc "Keys for drafting a follow-up prompt."
  "C-c C-c" #'roost-send-submit
  "C-c C-k" #'roost-send-cancel
  "C-c C-a" #'roost-send-attach
  "C-c C-v" #'roost-send-attach-image)

(define-derived-mode roost-send-mode text-mode "Roost Send"
  "Draft a follow-up prompt for a Roost task's agent.
\\{roost-send-mode-map}"
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-send-mode 'insert)
  (yank-media-handler "image/png" #'roost--send-yank-image)
  (roost--quiet-display))

(defconst roost--send-buttons
  '((" Cancel " roost-send-cancel roost-note-box-button
     "mouse-1 or \\<roost-send-mode-map>\\[roost-send-cancel]: discard the prompt")
    (" Attach " roost-send-attach roost-note-box-button
     "mouse-1 or \\<roost-send-mode-map>\\[roost-send-attach]: attach a file")
    (" Send " roost-send-submit roost-note-box-default-button
     "mouse-1 or \\<roost-send-mode-map>\\[roost-send-submit]: send it to the agent"))
  "The buttons in a prompt draft's header line.")

(defun roost--send-header (task)
  "Header line for TASK's follow-up draft, before its buttons."
  (substitute-command-keys
   (format " Send to %s · \\<roost-send-mode-map>\\[roost-send-submit] send · \\[roost-send-attach] attach · \\[roost-send-cancel] cancel"
           (roost--field task 'name))))

(defun roost--send-draft (task &optional initial)
  "Open a draft buffer for a follow-up to TASK, adding INITIAL.
An existing draft for TASK is reused and kept as written, with INITIAL
after it.  TASK's review notes not yet in the draft follow; sending the
draft clears those it holds as they are (see `roost-note')."
  (let ((buffer (roost--draft-buffer "send" 'roost--send-task task)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-send-mode) (roost-send-mode))
      (setq roost--send-task task
            ;; What became of sending it last is over.
            roost--draft-note nil
            header-line-format '(:eval (roost--draft-header (roost--send-header (roost--as-listed roost--send-task))
                                                            roost--send-buttons roost--send-sending)))
      (let* ((empty (string-blank-p (buffer-string)))
             (notes (progn
                      ;; Notes deleted with the rest of the text come back.
                      (when empty (setq roost--send-notes nil))
                      (seq-remove (lambda (note) (member (alist-get 'id note) roost--send-notes))
                                  (roost--task-notes task))))
             (addition (string-join (delq nil (cons initial (mapcar #'roost--format-note notes)))
                                    "\n\n")))
        (setq roost--send-notes (append roost--send-notes
                                        (mapcar (lambda (note) (alist-get 'id note)) notes)))
        (unless (string-empty-p addition)
          (when empty (erase-buffer))
          (goto-char (point-max))
          (delete-region (progn (skip-chars-backward " \t\n") (point)) (point-max))
          (insert "\n\n" addition))
        ;; In a new draft, leave point above the quoted text, ready for a
        ;; few words of your own.
        (goto-char (if (and empty (not (string-empty-p addition))) (point-min) (point-max)))))
    (pop-to-buffer buffer)))

(defun roost-send-cancel (&optional event)
  "Discard the follow-up draft, or the one whose Cancel button EVENT clicked."
  (interactive (list last-nonmenu-event))
  (roost--draft-clicked event 'roost-send-mode)
  ;; One of the draft's own, as for an attachment, would outlive it.
  (roost--quit-questions-here #'roost-send-cancel)
  (when (or (string-empty-p (string-trim (buffer-string)))
            (yes-or-no-p "Discard this prompt? "))
    (quit-window t)))

(defun roost--as-listed (task)
  "TASK as Roost last heard of it.
A draft holds the task it was opened for, which goes on changing."
  (or (gethash (roost--key task) roost--tasks) task))

(defun roost--send-draft-text ()
  "What sending the prompt draft would send."
  (replace-regexp-in-string "\\`\\([ \t]*\n\\)+" "" (string-trim-right (buffer-string))))

(defun roost--send-notes-going ()
  "The draft's review notes that sending it would send, each (ID . TEXT).
One you took out of it, or changed in it, isn't among them: the agent
wouldn't read it as it is, so it stays to be sent."
  (seq-keep (lambda (note)
              (when (and (member (alist-get 'id note) roost--send-notes)
                         (save-excursion
                           (goto-char (point-min))
                           (let ((case-fold-search nil))
                             (re-search-forward (roost--note-in-draft note) nil t))))
                (cons (alist-get 'id note) (alist-get 'text note))))
            (roost--notes)))

(defun roost--send-kept (task text notes)
  "Keep what the draft says beyond TEXT, which went to TASK with NOTES.
What went leaves the draft, if it is all still there: sending what is
left is what you wrote since.  NOTES are as `roost--send-notes-going'
gives them."
  (setq roost--send-sending nil
        roost--send-asked nil
        ;; Those that went, whatever is left of them here.
        roost--send-notes (seq-difference roost--send-notes (mapcar #'car notes)))
  ;; Narrowed to some of it, what is left could be out of sight.
  (widen)
  (let* ((start (save-excursion (goto-char (point-min))
                                (re-search-forward "\\`\\([ \t]*\n\\)*")
                                (point)))
         (end (+ start (length text)))
         (whole (and (<= end (point-max)) (equal (buffer-substring-no-properties start end) text))))
    (when whole
      (delete-region (point-min) end)
      ;; Blank lines alone: the indentation of what you wrote is yours.
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "\\`\\([ \t]*\n\\)*")
        (delete-region (point-min) (point))))
    ;; One you took out of it is yours to bring back.
    (setq roost--send-notes (mapcar #'car (roost--send-notes-going)))
    (setq roost--draft-note
          (format (if whole
                      " Sent to %s; this is what you wrote since"
                    " Sent to %s before you changed it; all of it is still here")
                  (roost--field task 'name))))
  (force-mode-line-update))

(defun roost-send-submit (&optional event)
  "Send the drafted follow-up.  The draft is kept if sending fails.
Review notes it holds as they are, and that stay so until it is sent,
are cleared then.  What you write in it meanwhile stays.  EVENT, a click
on the draft's Send button, says which draft."
  (interactive (list last-nonmenu-event))
  (roost--draft-clicked event 'roost-send-mode)
  (let ((text (roost--send-draft-text))
        ;; As it is now: it may have come to ask for permission.
        (task (roost--as-listed roost--send-task))
        (notes (roost--send-notes-going))
        (looked roost--send-notes)
        (buffer (current-buffer))
        (written (buffer-chars-modified-tick)))
    (when (string-empty-p (string-trim text))
      (user-error "Write a prompt first"))
    (let ((states (roost--attachment-states)))
      (when (memq 'copying states)
        (user-error "Still copying an attachment; send once its path is in"))
      (when (memq 'failed states)
        (user-error "An attachment didn't copy: delete its note, then attach it again if you like"))
      (when (memq 'stale states)
        (user-error "A [Copying …] is from a copy since done, as undo brings back: redo for its path, or delete it")))
    (when roost--send-sending
      (user-error "Already sending"))
    ;; Sending while its agent may be at a prompt asks first.
    (roost--quit-questions-here #'roost-send-submit)
    (unless (equal (car roost--send-asked) text)
      (setq roost--send-asked (cons text (roost--random-id))))
    (setq roost--send-sending t
          roost--draft-note nil)
    (condition-case err
        (roost--send-text
         task text
         (lambda (_task)
           ;; Closing waits for the minibuffer, so looking at what it says
           ;; does too: a question of the draft's own can add to it.
           (roost--when-out-of-minibuffer
            (lambda ()
              (let ((kept (and (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (save-restriction
                                   (widen)
                                   (not (equal (roost--send-draft-text) text)))))))
                (when kept
                  (with-current-buffer buffer (roost--send-kept task text notes)))
                ;; The prompt went, whatever becomes of this.
                (condition-case err
                    (when (roost--remove-notes
                           ;; As you sent it: one edited as it went stays.
                           (lambda (note) (equal (cdr (assoc (alist-get 'id note) notes)) (alist-get 'text note))))
                      (roost--redraw))
                  (error (message "Roost could not save your review notes: %s" (error-message-string err))))
                (unless kept (roost--close-buffer buffer))))))
         (lambda (err)
           (message "Roost could not send to %s: %s" (roost--field task 'name) err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq roost--send-sending nil)
               ;; The blank lines above it weren't sent, and the host counts
               ;; the lines it names from what was.  Anything written since
               ;; stays, and its lines were never counted.
               (when (= written (buffer-chars-modified-tick))
                 (delete-region (point-min) (save-excursion (goto-char (point-min))
                                                            (skip-chars-forward " \t\n")
                                                            (line-beginning-position))))
               (if (not (get-text-property 0 'roost-no-reply err))
                   (roost--draft-error "Could not send" err 'roost-send-submit)
                 ;; "Retries" would say too little, and the words of a
                 ;; request of any kind too much.
                 (setq roost--draft-note
                       (format " No reply from %s, and it may have gone · unchanged, %s sends it only if it didn't; edited, it goes as a new prompt"
                               (roost--host-label (roost--field task 'host))
                               (substitute-command-keys "\\[roost-send-submit]")))
                 (force-mode-line-update)))))
         ;; You have looked at what your notes are about, sent as you
         ;; wrote them or not.
         (and looked t)
         (cdr roost--send-asked))
      ;; A declined confirmation leaves the draft ready to send again.
      (quit (setq roost--send-sending nil) (signal (car err) (cdr err)))
      (error (setq roost--send-sending nil) (signal (car err) (cdr err))))))

;;;###autoload
(defun roost-send-region (start end)
  "Draft a prompt quoting region START to END with its file and lines.
Inside a task's worktree the prompt goes to that task, otherwise to a
chosen one.  A draft already begun keeps its text, and the quote follows."
  (interactive "r")
  (let* ((last (if (and (> end start) (eq (char-before end) ?\n)) (1- end) end))
         ;; As from an indirect buffer, or an Org source block being edited.
         (file (roost--source-file))
         (task (or (and file (roost--task-in-directory file))
                   (roost--read-task "Send region to task: "))))
    (roost--send-draft
     task
     (format "%s:%d-%d\n\n%s"
             (cond ((and file (roost--worktree-relative task file)))
                   (file (file-local-name file))
                   (t (buffer-name)))
             (roost--source-line start) (roost--source-line last)
             (buffer-substring-no-properties start end)))))

;;;; Attachments

(defconst roost--attach-limit (* 64 1024 1024)
  "Most bytes Roost copies to a host for one attachment.")

(defconst roost--scrawl-media '("mp4" "mov" "m4v" "wav" "m4a" "caf" "aac" "mp3")
  "Extensions of what Roost leaves of a Scrawl capture: video and audio.
They are most of its size, and an agent reads its frames instead.")

(defun roost--scrawl-capture-p (file)
  "Non-nil if FILE is the folder of a Scrawl capture."
  (and (file-directory-p file)
       (file-regular-p (expand-file-name "scrawl.json" file))
       (file-regular-p (expand-file-name "summary.md" file))))

(defun roost--scrawl-latest ()
  "The newest Scrawl capture on this machine, or nil."
  (let ((captures (expand-file-name (or (getenv "SCRAWL_CAPTURES_DIR")
                                        "~/Library/Application Support/scrawl/captures"))))
    (car (sort (seq-filter #'roost--scrawl-capture-p
                           (and (file-directory-p captures)
                                (directory-files captures t "\\.scrawl\\'")))
               #'file-newer-than-file-p))))

(defun roost--file-bytes (file &optional limit)
  "FILE's contents, as a unibyte string; with LIMIT, at most that many bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil (and limit 0) limit)
    (buffer-string)))

(defun roost--attachment-files (file)
  "The files to copy for FILE, as (NAME . LOCAL-FILE).
A Scrawl capture gives its folder's name and the files in it but its
video and audio; see `roost--scrawl-media'.  Signal a `user-error' for
what Roost won't attach: a folder, a file that isn't on this machine,
which an agent can be given by its path, or more than
`roost--attach-limit' bytes."
  (setq file (directory-file-name (expand-file-name file)))
  (when (file-remote-p file)
    (user-error "%s is on %s already: give the agent its path there"
                (file-local-name file) (file-remote-p file 'host)))
  (let* ((files (roost--attachment-entries file))
         ;; What a link points to, which is what Roost reads.
         (size (apply #'+ (mapcar (lambda (entry)
                                    ;; Not a pipe, say, which reading would
                                    ;; wait on, with Emacs.
                                    (unless (file-regular-p (cdr entry))
                                      (user-error "Can't read %s as a file" (cdr entry)))
                                    (file-attribute-size
                                     (or (file-attributes (file-truename (cdr entry)))
                                         (user-error "Can't read %s" (cdr entry)))))
                                  files))))
    (when (> size roost--attach-limit)
      (user-error "%s is %s; Roost attaches up to %s at once" (file-name-nondirectory file)
                  (file-size-human-readable size) (file-size-human-readable roost--attach-limit)))
    files))

(defun roost--attachment-entries (file)
  "The files to copy for FILE, an absolute name; see `roost--attachment-files'."
  (cond ((roost--scrawl-capture-p file)
         (let ((top (file-name-nondirectory file)))
           ;; Not hidden ones either, as Scrawl's own marks.
           (mapcan (lambda (path)
                     (unless (or (member (downcase (or (file-name-extension path) "")) roost--scrawl-media)
                                 (string-prefix-p "." (file-name-nondirectory path)))
                       (list (cons (concat top "/" (file-relative-name path file)) path))))
                   (directory-files-recursively
                    file "" nil (lambda (folder) (not (string-prefix-p "." (file-name-nondirectory folder))))))))
        ((file-directory-p file)
         (user-error "Roost attaches files and Scrawl captures, not folders"))
        ((file-readable-p file) (list (cons (file-name-nondirectory file) file)))
        (t (user-error "Can't read %s" file))))

(defconst roost--attach-rate 100000
  "Bytes a second Roost counts on to copy an attachment, at the least.
A copy may take `roost-request-timeout' seconds and this long besides,
so a large one over a slow link gets its time.")

(defun roost--attach (task files success failure)
  "Copy FILES, as (NAME . BYTES), to TASK's host in the background.
Call SUCCESS with their path there, or FAILURE with a message.  NAMES
share a first part, a file's or a folder's, which the host may number to
keep it apart from those already there."
  (let ((size (apply #'+ (mapcar (lambda (file) (length (cdr file))) files))))
    ;; What was read, which may have grown since it was looked at.
    (when (> size roost--attach-limit)
      (user-error "The attachment is %s; Roost attaches up to %s at once"
                  (file-size-human-readable size) (file-size-human-readable roost--attach-limit)))
    (roost--request (roost--field task 'host) "attach"
                    `((id . ,(roost--field task 'id))
                      (files . ,(vconcat
                                 (mapcar (lambda (file)
                                           `((name . ,(car file))
                                             (data . ,(base64-encode-string (cdr file) t))))
                                         files))))
                    (lambda (result) (funcall success (car (alist-get 'paths result))))
                    failure
                    (+ roost-request-timeout (/ size roost--attach-rate)))))

(defun roost--attach-file (task file entries success failure)
  "Copy FILE, whose ENTRIES `roost--attachment-files' lists, to TASK's host.
It is copied in the background: call SUCCESS with what a prompt says of
it, or FAILURE with a message.
What it says is its path there; for a Scrawl capture, also where its
contact sheet and frames are, and its summary."
  (let ((summary (when (roost--scrawl-capture-p file)
                   ;; Which names the capture where it was made.
                   (string-trim (with-temp-buffer
                                  (insert-file-contents (expand-file-name "summary.md" file))
                                  (buffer-string))))))
    ;; A byte past the limit at most, as it may have grown since: enough
    ;; for `roost--attach' to refuse it, without reading all of it.
    (roost--attach task (mapcar (lambda (entry)
                                  (cons (car entry) (roost--file-bytes (cdr entry) (1+ roost--attach-limit))))
                                entries)
                   (lambda (path)
                     (funcall success
                              (if (not summary)
                                  path
                                (concat (format "A Scrawl recording of my screen, in %s: contact-sheet.png shows its keyframes, numbered as below, each in frames/; scrawl.json has the rest.\n\n"
                                                path)
                                        (roost--scrawl-summary-at summary file path)))))
                   failure)))

(defun roost--scrawl-summary-at (summary capture path)
  "SUMMARY of Scrawl CAPTURE, naming its copy at PATH instead.
Its first line names the capture where Scrawl made it, which may have
moved since, or been reached through a link."
  (dolist (name (delete-dups
                 (delq nil (list (and (string-match "\\`\\[scrawl .* · \\(/[^]\n]*\\.scrawl\\)\\]" summary)
                                      (match-string 1 summary))
                                 (directory-file-name (expand-file-name capture))
                                 (directory-file-name (file-truename capture)))))
           summary)
    (setq summary (string-replace name path summary))))

(defconst roost--clipboard-png-script
  "on run argv
set f to open for access (POSIX file (item 1 of argv)) with write permission
try
write (the clipboard as «class PNGf») to f
end try
close access f
end run"
  "AppleScript writing the clipboard's image as PNG to a file, or nothing.")

(defun roost--clipboard-image ()
  "The image on the clipboard as PNG bytes, or nil."
  (or (when-let* ((data (ignore-errors (gui-get-selection 'CLIPBOARD 'image/png)))
                  ((stringp data))
                  ((not (string-empty-p data))))
        (if (multibyte-string-p data) (encode-coding-string data 'raw-text) data))
      (when (eq system-type 'darwin)
        (let ((file (make-temp-file "roost-clipboard-" nil ".png")))
          (unwind-protect
              (when (eq 0 (call-process "osascript" nil nil nil "-e" roost--clipboard-png-script file))
                (let ((data (roost--file-bytes file)))
                  (unless (string-empty-p data) data)))
            (delete-file file))))))

(defun roost--attach-image (task png success failure)
  "Copy image PNG, its bytes, to TASK's host in the background.
Call SUCCESS with its path there, or FAILURE with a message."
  (roost--attach task (list (cons (format-time-string "clipboard-%Y%m%d-%H%M%S.png") png))
                 success failure))

(defvar roost--attachment-count 0
  "Attachments begun in this Emacs, which numbers each one's place in a draft.")

(defun roost--attachment-placeholder (id name)
  "What a draft shows of attachment ID, NAME, while it is copied."
  (propertize (format "[Copying %s…]" name)
              'roost-attachment id 'roost-attachment-state 'copying 'font-lock-face 'shadow))

(defvar-local roost--attachments-copying nil
  "This draft's attachments still copying, by number.
A placeholder of one not among them, as undo brings back, is stale.")

(defun roost--attachment-done (buffer id text &optional error)
  "Put TEXT in place of attachment ID's placeholder in draft BUFFER.
With ERROR, the attachment, named TEXT, failed to copy: put a note of
that there instead, which stays until you delete it."
  (when error
    (message "Roost could not attach %s: %s" text error))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq roost--attachments-copying (delq id roost--attachments-copying))
      (save-restriction
        (widen)
        ;; Each copy of it you made, and none if you deleted it meanwhile.
        (let (start)
          (while (setq start (roost--attachment-placeholder-at id))
            (let* ((end (or (next-single-property-change start 'roost-attachment) (point-max)))
                   (new (if error
                            (propertize (format "[Not attached: %s: %s]" text error)
                                        'roost-attachment id 'roost-attachment-state 'failed
                                        'font-lock-face 'error)
                          text))
                   (point (point)))
              ;; A step of its own to undo, apart from your writing.
              (undo-boundary)
              (goto-char start)
              (delete-region start end)
              (insert new)
              (undo-boundary)
              (goto-char (cond ((< point start) point)
                               ((>= point end) (+ point (- (length new) (- end start))))
                               (t start))))))))))

(defun roost--attachment-placeholder-at (id)
  "Where a placeholder of attachment ID, still copying, starts, or nil."
  (let ((position (point-min)) found)
    (while (and (not found)
                (setq position (text-property-any position (point-max) 'roost-attachment id)))
      (if (eq (get-text-property position 'roost-attachment-state) 'copying)
          (setq found position)
        (setq position (or (next-single-property-change position 'roost-attachment) (point-max)))))
    found))

(defun roost--attachment-states ()
  "The states of the draft's attachments not yet in it.
`copying', `failed', or `stale' for the placeholder of a copy since done."
  (let ((position (point-min)) states)
    (while (setq position (text-property-not-all position (point-max) 'roost-attachment-state nil))
      (let ((state (get-text-property position 'roost-attachment-state)))
        (push (if (and (eq state 'copying)
                       (not (memq (get-text-property position 'roost-attachment)
                                  roost--attachments-copying)))
                  'stale
                state)
              states))
      (setq position (or (next-single-property-change position 'roost-attachment-state) (point-max))))
    states))

(defun roost--send-attach-start (task name copy)
  "Attach NAME to the draft for TASK: a placeholder now, COPY's result later.
COPY is called with TASK, a success and a failure function, and copies
in the background.  An error it signals at once, as for a file too big,
or a quit while it reads the file, leaves no placeholder."
  (let ((buffer (current-buffer))
        (id (cl-incf roost--attachment-count))
        (from (point)))
    (roost--send-insert-attachment (roost--attachment-placeholder id name))
    (push id roost--attachments-copying)
    (let ((to (point)))
      (condition-case err
          (funcall copy task
                   (lambda (text) (roost--attachment-done buffer id text))
                   (lambda (error) (roost--attachment-done buffer id name error)))
        ((error quit)
         (setq roost--attachments-copying (delq id roost--attachments-copying))
         ;; All it inserted, the line it broke included.
         (delete-region from to)
         (signal (car err) (cdr err)))))))

(defun roost--send-insert-attachment (text)
  "Insert TEXT, about an attachment, at point in the draft, on lines of its own.
What followed point goes on the line after it, where point goes too: on
an empty line, that stays empty, to write on."
  (unless (bolp) (insert "\n"))
  (insert text "\n"))

(defun roost--read-attachment ()
  "Read a file or Scrawl capture to attach; \\`M-n' gives the newest capture.
It is on this machine: the question starts here, not in a remote task's
worktree."
  (let ((default-directory (if (file-remote-p default-directory)
                               (expand-file-name "~/")
                             default-directory)))
    ;; Expanded here, where a name you typed was meant.
    (expand-file-name (read-file-name "Attach file or Scrawl capture: " nil (roost--scrawl-latest) t))))

(defun roost-send-attach (file)
  "Attach FILE to the drafted prompt.
Roost copies it to the task's host in the background, where the agent
can read it, and puts its path in place of \"[Copying FILE…]\", or a
note that it failed.  For a Scrawl capture's folder (\\`M-n' gives the
newest), it copies all but its video and audio, and adds its summary.
The copies go when the task does."
  (interactive (progn
                 ;; From its Attach button, the draft clicked.
                 (roost--draft-clicked last-nonmenu-event 'roost-send-mode)
                 (roost--attaching-task)
                 (roost--quit-questions-here
                  (lambda () (call-interactively #'roost-send-attach)))
                 (list (roost--read-attachment))))
  (roost--send-attach-file file (roost--attachment-files file)))

(defun roost--attaching-task ()
  "The task of the prompt draft you are in, which you attach to."
  (or roost--send-task (user-error "Not in a prompt draft; M-x roost-attach starts one")))

(defun roost--send-attach-file (file entries)
  "Attach FILE, whose ENTRIES `roost--attachment-files' lists, to the draft."
  (roost--send-attach-start (roost--attaching-task) (file-name-nondirectory (directory-file-name file))
                            (lambda (task success failure)
                              (roost--attach-file task file entries success failure))))

(defun roost--send-attach-png (png)
  "Attach PNG, an image's bytes, to the draft."
  (roost--send-attach-start (roost--attaching-task) "the image"
                            (lambda (task success failure)
                              (roost--attach-image task png success failure))))

(defun roost-send-attach-image ()
  "Attach the image on the clipboard to the drafted prompt.
Roost copies it to the task's host as a PNG file and adds its path; see
`roost-send-attach'."
  (interactive)
  (roost--attaching-task)
  (roost--send-attach-png (or (roost--clipboard-image) (user-error "No image on the clipboard"))))

(defun roost--send-yank-image (_type png)
  "Attach PNG, an image `yank-media' found on the clipboard, to the draft."
  (roost--send-attach-png (if (multibyte-string-p png) (encode-coding-string png 'raw-text) png)))

;;;###autoload
(defun roost-attach (files &optional task)
  "Draft a prompt to TASK attaching FILES, a file name or a list of them.
In Dired, FILES are the marked files.  Roost copies each to the task's
host and adds its path; see `roost-send-attach'.  TASK is the task of
the current terminal or worktree file, or one you choose.  Roost checks
them all before copying any."
  (interactive (list (if (derived-mode-p 'dired-mode)
                         (dired-get-marked-files)
                       (roost--read-attachment))))
  ;; Expanded here: the draft has a directory of its own.
  (setq files (mapcar #'expand-file-name (if (stringp files) (list files) files)))
  (let ((entries (mapcar #'roost--attachment-files files)))
    (setq task (roost--choose task))
    (roost--send-draft task)
    ;; After what the draft holds, and in a new one, under a line to write on.
    (let ((at (copy-marker (point))))
      (goto-char (point-max))
      (if (bobp) (insert "\n\n") (unless (bolp) (insert "\n")))
      (cl-mapc #'roost--send-attach-file files entries)
      (goto-char at))))

;;;; Review notes

(defvar roost--notes nil
  "Review notes not yet sent to an agent, oldest first; see `roost-note'.
Each is an alist: `id'; `host' and `task' name its task; `file' is
relative to the task's worktree; `line' and `end' are the first and last
lines noted, absent for the whole file; `removed' means they number the
old version's lines; `quote' holds the noted diff lines; `text' is the
note.")
(defvar roost--notes-loaded nil
  "Non-nil once `roost-notes-file' has been read.")

(defvar roost--note-box nil
  "The review note being written, as a plist, or nil.
`:buffer' is the box's buffer, `:task' the note's task, `:place' what it
is about and `:old' the note it edits, if any.  `:window' and `:source'
are the Magit window and buffer it was opened from.  Where Emacs shows
child frames, the box is `:frame', over `:room' pixels left for it.")

(defvar-keymap roost--note-shown-map
  :doc "Mouse keys on a review note shown in Magit."
  "<mouse-1>" #'roost-note-mouse-menu
  "<down-mouse-3>" #'roost-note-mouse-menu)

(defvar roost--note-button nil
  "Overlay showing the note button beside the line under the mouse.")
(defvar roost--note-mouse-timer nil
  "Timer moving the note button with the mouse, where the text cannot.")

(defun roost--notes ()
  "All review notes not yet sent, read from `roost-notes-file' once."
  (unless roost--notes-loaded
    (setq roost--notes-loaded t
          roost--notes (seq-filter #'consp (roost--read-remembered roost-notes-file))))
  roost--notes)

(defun roost--notes-as-on-file ()
  "Take up the notes `roost-notes-file' holds, if another Emacs changed them.
By ID: a note that is still there stays the same object, as the note box
or a draft may hold it."
  (let* ((held (roost--notes))
         (notes (roost--read-again roost-notes-file))
         edited)
    (unless (eq notes 'same)
      (setq roost--notes
            (mapcar (lambda (note)
                      (let* ((id (alist-get 'id note))
                             (mine (seq-find (lambda (old) (equal (alist-get 'id old) id)) held))
                             (text (alist-get 'text note)))
                        (when (and mine (not (equal (alist-get 'text mine) text)))
                          (push (cons (copy-tree mine) mine) edited)
                          (setf (alist-get 'text mine) text))
                        (or mine note)))
                    (seq-filter #'consp notes)))
      (pcase-dolist (`(,before . ,note) edited) (roost--update-drafts before note))
      (dolist (note (seq-difference held roost--notes #'eq))
        (roost--update-drafts note nil))
      (roost--show-notes-everywhere))))

(defun roost--save-notes ()
  "Write the review notes to `roost-notes-file'."
  (roost--write-json-list
   roost-notes-file
   (mapcar (lambda (note)
             ;; JSON has no nil: absent fields stay out, and lists are arrays.
             (seq-keep (lambda (field)
                         (when-let* ((value (cdr field)))
                           (cons (car field)
                                 (cond ((consp value) (vconcat value))
                                       ;; A note that can't be sent as it is
                                       ;; still mustn't stop any being saved.
                                       ((stringp value) (roost--shown-text value))
                                       (t value)))))
                       note))
           roost--notes)))

(defun roost--note-key (note)
  "The key of NOTE's task."
  (list (alist-get 'host note) (alist-get 'task note)))

(defun roost--task-notes (task)
  "TASK's review notes not yet sent, oldest first."
  (let ((key (roost--key task)))
    (seq-filter (lambda (note) (equal (roost--note-key note) key)) (roost--notes))))

(defun roost--remove-notes (predicate)
  "Remove the review notes PREDICATE accepts; return non-nil if any were.
Drafts holding them lose them too."
  (roost--notes-as-on-file)
  (when-let* ((removed (seq-filter predicate (roost--notes))))
    (setq roost--notes (seq-difference roost--notes removed #'eq))
    (roost--save-notes)
    (dolist (note removed) (roost--update-drafts note nil))
    (roost--show-notes-everywhere)
    t))

(defun roost--edit-note (note text)
  "Make TEXT the text of review NOTE, in the drafts holding it too."
  (let ((before (copy-tree note)))
    (setf (alist-get 'text note) text)
    (roost--save-notes)
    (roost--update-drafts before note)))

(defun roost--note-in-draft (note)
  "A regexp for NOTE as a draft holds it, a block of its own, the first group.
A blank line or the end of the draft follows it: a line added to it
makes it another note."
  (concat "^\\(" (regexp-quote (roost--format-note note)) "\\)\\(?:\n[ \t]*\n\\|[ \t\n]*\\'\\)"))

(defun roost--update-drafts (old new)
  "Replace note OLD with NEW in the drafts holding it; nil NEW removes it.
A draft in which you have changed the note's text keeps your text, and
no longer counts the note as its own, so sending it leaves the note."
  (let ((id (alist-get 'id old))
        (before (roost--note-in-draft old))
        (case-fold-search nil))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'roost-send-mode) (member id roost--send-notes)
                   ;; On its way: what it says now hasn't gone, so it stays a
                   ;; note, and what the draft says, what it sent.
                   (or (not roost--send-sending)
                       (progn (setq roost--send-notes (delete id roost--send-notes)) nil)))
          (save-excursion
            (goto-char (point-min))
            ;; The note as it was drafted, on lines of its own.
            (cond ((not (re-search-forward before nil t))
                   (setq roost--send-notes (delete id roost--send-notes)))
                  (new (replace-match (roost--format-note new) t t nil 1))
                  (t
                   (replace-match "" t t nil 1)
                   (goto-char (match-beginning 1))
                   (setq roost--send-notes (delete id roost--send-notes))
                   ;; One blank line between the notes either side.
                   (delete-region (progn (skip-chars-backward "\n") (point))
                                  (progn (skip-chars-forward "\n") (point)))
                   (unless (eobp) (insert "\n\n"))))))))))

(defun roost--note-location (note)
  "Where NOTE is: its file, then its lines if it is not about the whole file."
  (let ((line (alist-get 'line note))
        (end (alist-get 'end note)))
    (concat (alist-get 'file note)
            (when line
              (concat (if (equal line end) (format ":%d" line) (format ":%d-%d" line end))
                      (when (alist-get 'removed note)
                        (if (equal line end) " (a removed line)" " (removed lines)")))))))

(defconst roost--note-quote-lines 8
  "How many of its lines a note quotes to the agent.")

(defun roost--format-note (note)
  "NOTE as its agent reads it: where it is, the lines quoted, then the note."
  (let ((quote (alist-get 'quote note)))
    (concat (roost--note-location note) "\n"
            (mapconcat (lambda (line) (concat "> " line "\n"))
                       (seq-take quote roost--note-quote-lines) "")
            (when (length> quote roost--note-quote-lines) "> …\n")
            (alist-get 'text note))))

(defun roost--notes-summary (task)
  "How many review notes TASK has, and the key that sends them, or nil."
  (when-let* ((notes (roost--task-notes task)))
    (substitute-command-keys
     (format "%d review note%s for the agent; \\<roost-task-info-mode-map>\\[roost-send] sends %s"
             (length notes) (if (cdr notes) "s" "") (if (cdr notes) "them" "it")))))

;;;###autoload
(defun roost-discard-notes (&optional task)
  "Discard TASK's review notes without sending them."
  (interactive)
  (setq task (roost--choose task))
  (let ((count (length (roost--task-notes task))))
    (when (zerop count)
      (user-error "%s has no review notes" (roost--field task 'name)))
    (when (yes-or-no-p (format "Discard %d review note%s for %s? "
                               count (if (= count 1) "" "s") (roost--field task 'name)))
      (roost--remove-notes (lambda (note) (equal (roost--note-key note) (roost--key task))))
      (roost--redraw)
      (message "Discarded the review notes for %s" (roost--field task 'name)))))

;;;; Review in Magit

(defvar-keymap roost-magit-mode-map
  :doc "Roost's keys in Magit on a task's worktree."
  ";" #'roost-note
  "'" #'roost-goto-note
  "C-c ;" #'roost-note-actions
  "=" #'roost-diff-whole-file
  "@" #'roost-send
  ;; As in the task's terminal.
  "C-c ?" #'roost-dispatch
  ;; The note button, beside the diff line under the mouse.
  "<left-margin> <mouse-1>" #'roost-note-mouse
  "<left-margin> <drag-mouse-1>" #'roost-note-mouse)

(easy-menu-define roost-magit-menu roost-magit-mode-map
  "Menu for Roost in Magit on a task's worktree."
  '("Roost"
    ["Note on This Line…" roost-note]
    ["Go to Note…" roost-goto-note]
    ["Note Actions…" roost-note-actions]
    ["Whole-File Diff" roost-diff-whole-file]
    ["Send to the Agent…" roost-send]
    ["Discard Notes…" roost-discard-notes]
    "---"
    ["Agent's Terminal" roost-open-task]
    ["Task Panel" roost-task-info]))

(defvar roost--magit-evil-keys nil
  "Non-nil once Roost's keys in Magit have Evil bindings.")

(define-minor-mode roost-magit-mode
  "Notes for the agent and other Roost keys, in Magit on a task's worktree.
Roost turns it on in Magit buffers whose repository is a task's worktree.
With Evil, the keys work in normal and visual state too, except that
the whole file's diff is on `g=', since evil-collection gives `=' to
less diff context.
\\{roost-magit-mode-map}"
  :lighter nil
  (when (and roost-magit-mode (fboundp 'evil-define-minor-mode-key))
    (unless roost--magit-evil-keys
      (setq roost--magit-evil-keys t)
      (evil-define-minor-mode-key '(normal visual motion) 'roost-magit-mode
        ";" #'roost-note
        "'" #'roost-goto-note
        "@" #'roost-send
        "g=" #'roost-diff-whole-file))
    (evil-normalize-keymaps))
  (roost--note-hover-setup))

(defvar-local roost--note-overlays nil
  "Overlays showing review notes in this Magit buffer.")
;; Magit calls its mode again on a buffer it reuses, which kills local
;; variables but leaves the buffer's overlays: forgotten, a note would
;; show again at the top.
(put 'roost--note-overlays 'permanent-local t)

(defun roost--magit-setup ()
  "Add Roost's notes, keys and task header to Magit on task worktrees."
  (add-hook 'magit-refresh-buffer-hook #'roost--magit-buffer-refreshed)
  (magit-add-section-hook 'magit-status-headers-hook #'roost--magit-insert-task-header nil t)
  (magit-add-section-hook 'magit-status-sections-hook #'roost--magit-insert-reply
                          'magit-insert-status-headers t)
  ;; Where Magit lists commits; at the end if you have removed those.
  (let ((at (seq-find (lambda (inserter) (memq inserter (default-value 'magit-status-sections-hook)))
                      '(magit-insert-unpushed-to-upstream-or-recent
                        magit-insert-unpushed-to-upstream magit-insert-recent-commits))))
    (magit-add-section-hook 'magit-status-sections-hook #'roost--magit-insert-unmerged
                            at (not at)))
  (magit-add-section-hook 'magit-status-sections-hook #'roost--magit-insert-since-looked
                          #'roost--magit-insert-unmerged))

(defun roost--magit-teardown ()
  "Remove what `roost--magit-setup' added, from Magit and its buffers."
  ;; Removing from a hook Magit has not defined yet would define it empty.
  (when (featurep 'magit)
    (remove-hook 'magit-refresh-buffer-hook #'roost--magit-buffer-refreshed)
    (remove-hook 'magit-status-headers-hook #'roost--magit-insert-task-header)
    (remove-hook 'magit-status-sections-hook #'roost--magit-insert-reply)
    (remove-hook 'magit-status-sections-hook #'roost--magit-insert-unmerged)
    (remove-hook 'magit-status-sections-hook #'roost--magit-insert-since-looked))
  (roost--note-box-close)
  (when (timerp roost--note-mouse-timer)
    (cancel-timer roost--note-mouse-timer)
    (setq roost--note-mouse-timer nil))
  (when (overlayp roost--note-button)
    (delete-overlay roost--note-button))
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'roost-magit-mode buffer)
      (with-current-buffer buffer
        (mapc #'delete-overlay roost--note-overlays)
        (setq roost--note-overlays nil)
        (roost-magit-mode -1)))))

(defun roost--magit-buffer-refreshed ()
  "Give a Magit buffer on a task's worktree Roost's keys and its notes.
Run from Magit's hook, so an error only reports itself."
  (with-demoted-errors "Roost: %S"
    (let ((task (roost--task-in-directory default-directory)))
      (unless (eq (not task) (not roost-magit-mode))
        (roost-magit-mode (if task 1 -1)))
      (roost--show-notes-here task)
      ;; Magit has inserted the buffer's text anew.
      (roost--note-hover-setup)
      (when (eq (plist-get roost--note-box :source) (current-buffer))
        (roost--note-box-follow)))))

(defun roost--magit-insert-task-header ()
  "In Magit's status of a task's worktree, insert a header naming the task.
See `roost-magit-status-sections'."
  (when-let* ((roost-magit-status-sections)
              (task (roost--task-in-directory default-directory)))
    (roost--magit-insert-section
     'roost-task (roost--key task) nil
     (lambda () (roost--insert-task-header task)))))

(defun roost--insert-task-header (task)
  "Insert the line naming TASK in Magit's status of its worktree.
Like the rest of the status, it holds until Magit refreshes, so it leaves
out the agent's status, which changes while you read."
  (let ((integration (roost--field task 'integrationBranch)))
    (insert (format "%-10s" "Task: ")
            (propertize (roost--field task 'name) 'font-lock-face 'bold)
            (if integration
                (propertize (format ", merges into %s" integration) 'font-lock-face 'roost-dim)
              "")
            "\n")))

(defun roost--magit-insert-reply ()
  "In Magit's status of a task's worktree, insert the agent's latest reply.
It starts folded, showing its first line.  See `roost-magit-status-sections'."
  (when-let* ((roost-magit-status-sections)
              (task (roost--task-in-directory default-directory))
              (reply (roost--last-message task)))
    (roost--magit-insert-section
     'roost-reply nil t
     (lambda ()
       ;; With faces of its own, the heading is inserted as it is.  It
       ;; has to fit on one line.
       (let* ((title "Agent's latest reply")
              (window (get-buffer-window nil t))
              (room (- (if window (window-body-width window) 80) (length title) 3)))
         (magit-insert-heading
           (propertize title 'face 'magit-section-heading)
           (when (> room 10)
             (propertize (concat "  " (truncate-string-to-width
                                       (or (roost--last-message-summary task) "") room nil nil "…"))
                         'face 'roost-dim))))
       (insert (replace-regexp-in-string "^" "  " reply) "\n\n")))))

(defun roost--magit-insert-unmerged ()
  "In Magit's status of a task's worktree, insert the commits to review.
They are the task's commits not yet in the branch it merges into.  A
task's branch has no upstream, so Magit itself shows only recent
commits, and the work an agent committed would have no place there.
As in Magit's own sections of unmerged commits, RET on the heading shows
their changes together.  See `roost-magit-status-sections'."
  (when-let* ((roost-magit-status-sections)
              (task (roost--task-in-directory default-directory))
              (integration (roost--field task 'integrationBranch))
              ((stringp integration))
              ;; Magit shows the commits itself then.
              ((not (equal (magit-get-upstream-branch) integration)))
              ;; The branch, not a tag of its name.
              (ref (concat "refs/heads/" integration))
              ((magit-rev-verify ref)))
    (let ((range (concat ref "..")))
      (roost--magit-insert-section
       'unpushed range nil
       (lambda ()
         (magit-insert-heading
           (format (propertize "Unmerged into %s." 'font-lock-face 'magit-section-heading)
                   integration))
         ;; With no commits, Magit leaves the section out.  Magit 3
         ;; has the function under its older name.
         (if (fboundp 'magit--insert-log)
             (magit--insert-log nil range magit-buffer-log-args)
           (magit-insert-log range magit-buffer-log-args))
         (magit-log-insert-child-count))))))

(defvar-keymap roost-since-looked-section-map
  :doc "Keys on what changed since you last looked, in Magit's status of a task."
  "<remap> <magit-visit-thing>" #'roost-diff-since-looked)

(defun roost--magit-insert-since-looked ()
  "In Magit's status of a task's worktree, insert what changed since you looked.
That is between the last two times you looked at the task, as by
opening it in Magit with `roost-review', sending its agent your notes
or `roost-mark-looked', the last one often this time: its files.  RET
on the heading shows their changes together, as on Magit's sections of
unmerged commits, and on a file, its own.  See `roost-magit-status-sections'."
  (when-let* ((roost-magit-status-sections)
              (task (roost--task-in-directory default-directory))
              (looked (roost--field task 'looked))
              (since (alist-get 'since looked))
              (files (alist-get 'files since))
              (start (alist-get 'start since))
              ;; As recorded by an older helper, the look's own commit.
              (end (or (alist-get 'end since) (alist-get 'commit looked)))
              ;; Git prunes what a look kept of uncommitted work in time.
              ((magit-rev-verify (concat start "^{commit}")))
              ((magit-rev-verify (concat end "^{commit}"))))
    ;; The files its diff is of go with the section, as the task's record
    ;; may change before you press RET: all of them, unless some of the
    ;; files that changed were only the integration branch's.
    (roost--magit-insert-section
     'roost-since-looked (list (concat start ".." end) (alist-get 'paths since)) nil
     (lambda ()
       (roost--magit-section-keymap 'roost-since-looked-section-map)
       (magit-insert-heading
         (propertize "Changed since you last looked" 'font-lock-face 'magit-section-heading)
         (propertize (format ", %s ago" (roost--elapsed (alist-get 'at since))) 'font-lock-face 'roost-dim)
         (format " (%d)" (or (alist-get 'count since) (length files))))
       (dolist (file files)
         (let ((path (alist-get 'path file)))
           (roost--magit-insert-section
            'roost-since-looked-file path nil
            (lambda ()
              (roost--magit-section-keymap 'roost-since-looked-section-map)
              ;; Magit's font lock would take away faces of other kinds.
              (insert (propertize path 'font-lock-face 'magit-filename)
                      (if (alist-get 'added file)
                          (concat "  " (propertize (format "+%d" (alist-get 'added file))
                                                   'font-lock-face 'roost-diff-added)
                                  " " (propertize (format "−%d" (alist-get 'deleted file))
                                                  'font-lock-face 'roost-diff-removed))
                        (propertize "  binary" 'font-lock-face 'roost-dim))
                      "\n")))))
       (when-let* ((more (- (or (alist-get 'count since) 0) (length files)))
                   ((> more 0)))
         (insert (propertize (format "%d more\n" more) 'font-lock-face 'roost-dim)))
       (insert "\n")))))

(defun roost--magit-section-keymap (keymap)
  "Give the Magit section being inserted KEYMAP, a symbol.
As its own sections have, from Magit 3; an older Magit keeps its own keys.
Magit is optional, so its section classes are unknown when Roost is
compiled."
  (let ((slot 'keymap))
    (ignore-errors (eieio-oset magit-insert-section--current slot keymap))))

(defun roost-diff-since-looked ()
  "Show what changed since you last looked at the task, in Magit.
That is between the last two times you looked; on a file, only its
changes.  As in any diff of the task, \\<roost-magit-mode-map>\\[roost-note] writes a note for its agent."
  (interactive)
  (let* ((section (magit-current-section))
         (file (when (eq (roost--slot section 'type) 'roost-since-looked-file)
                 (prog1 (roost--slot section 'value)
                   (setq section (roost--slot section 'parent))))))
    (unless (eq (roost--slot section 'type) 'roost-since-looked)
      (user-error "Put point on what changed since you last looked"))
    (pcase-let ((`(,range ,paths) (roost--slot section 'value)))
      (magit-diff-range range (car (magit-diff-arguments)) (if file (list file) paths)))))

(defun roost--magit-insert-section (type value hide insert)
  "Insert a Magit section of TYPE with VALUE, folded if HIDE, using INSERT.
Magit is optional, so its section macro is expanded only once it is in
use."
  (eval `(magit-insert-section (,type ',value ,hide) (funcall ',insert)) t))

(defun roost--slot (section slot)
  "SLOT of Magit's SECTION.
Magit is optional, so its section classes are unknown when Roost is
compiled."
  (eieio-oref section slot))

(defun roost--hunk-lines (hunk)
  "The lines of Magit's HUNK section, each as (POSITION SIDE NUMBER TEXT).
SIDE is `old' for a removed line and `new' for any other, and NUMBER is
its line number on that side.  TEXT leaves out the diff marker.
A combined diff, of a merge with conflicts, has none."
  (let ((from (roost--slot hunk 'from-range))
        (to (roost--slot hunk 'to-range)))
    (when (and from to (not (roost--slot hunk 'combined)))
      (save-excursion
        ;; All its lines, though the buffer is narrowed to some: there
        ;; `forward-line' stops short of the hunk's end.
        (save-restriction
          (widen)
          (goto-char (roost--slot hunk 'content))
          (let ((old (car from)) (new (car to)) (end (roost--slot hunk 'end)) lines)
            (while (and (< (point) end) (not (eobp)))
              (let ((text (roost--shown-text
                           (buffer-substring-no-properties
                            (min (1+ (point)) (line-end-position)) (line-end-position)))))
                (pcase (char-after)
                  (?- (push (list (point) 'old old text) lines) (cl-incf old))
                  (?+ (push (list (point) 'new new text) lines) (cl-incf new))
                  (?\s (push (list (point) 'new new text) lines) (cl-incf old) (cl-incf new))))
              (forward-line))
            (nreverse lines)))))))

(defun roost--magit-note-place ()
  "What a note written at point would be about, as part of a note.
In a hunk that is the line at point, the lines in the region, or on its
heading the whole hunk; on a file's name, the whole file.  A region
must stay within one hunk."
  (let ((section (magit-current-section)))
    (when (and (use-region-p)
               (not (and (magit-section-match 'hunk section)
                         (<= (roost--slot section 'start) (region-beginning))
                         (<= (region-end) (roost--slot section 'end)))))
      (user-error "Select lines within one hunk; write a note for each hunk"))
    (cond
     ((magit-section-match 'hunk section)
      ;; By whole lines, though the buffer is narrowed to part of one.
      (save-restriction
        (widen)
        (let* ((lines (or (roost--hunk-lines section)
                          (user-error "Roost cannot place notes in a combined diff")))
               (from (save-excursion
                       (goto-char (if (use-region-p) (region-beginning) (point)))
                       (line-beginning-position)))
               (to (if (not (use-region-p))
                       (line-end-position)
                     ;; A region ending where a line starts leaves that line out.
                     (let ((end (region-end)))
                       (if (and (> end from) (save-excursion (goto-char end) (bolp)))
                           (1- end)
                         end))))
               (chosen (or (seq-filter (lambda (line) (<= from (car line) to)) lines)
                           lines))
               (numbered (or (seq-remove (lambda (line) (eq (nth 1 line) 'old)) chosen)
                             chosen)))
          `((file . ,(roost--slot (roost--slot section 'parent) 'value))
            (line . ,(nth 2 (car numbered)))
            (end . ,(nth 2 (car (last numbered))))
            ,@(when (eq (nth 1 (car numbered)) 'old) '((removed . t)))
            ;; The note shows under the last line chosen, though that may be
            ;; a removed line after lines numbered in the new version.
            (anchorLine . ,(nth 2 (car (last chosen))))
            ,@(when (eq (nth 1 (car (last chosen))) 'old) '((anchorOld . t)))
            (quote . ,(mapcar (lambda (line)
                                (save-excursion
                                  (goto-char (car line))
                                  (roost--shown-text
                                   (buffer-substring-no-properties (point) (line-end-position)))))
                              chosen))))))
     ((magit-section-match 'file section)
      `((file . ,(roost--slot section 'value))))
     (t (user-error "Put point on a changed line, or a file's name, in a diff")))))

(defun roost--note-anchor (note)
  "The line NOTE shows under, as (SIDE NUMBER TEXT) like `roost--hunk-lines'.
Notes written before `anchorLine' was recorded show under their last
line on the side they are numbered by."
  (let* ((old (if (alist-get 'anchorLine note)
                  (alist-get 'anchorOld note)
                (alist-get 'removed note)))
         (line (car (last (seq-filter (lambda (line) (eq (string-prefix-p "-" line) (and old t)))
                                      (alist-get 'quote note))))))
    (list (if old 'old 'new)
          (or (alist-get 'anchorLine note) (alist-get 'end note))
          (and line (substring line (min 1 (length line)))))))

(defun roost--note-positions (note headings lines)
  "Where this buffer shows NOTE: line ends after which it goes.
A note on a whole file goes after each of HEADINGS, the ends of its
file's headings.  Otherwise it goes after its last line among LINES, its
file's lines from `roost--hunk-lines'.  When that line has moved, as
when the agent has edited the file since, the nearest line with the same
text stands in for it."
  (if (not (alist-get 'line note))
      headings
    (pcase-let* ((`(,side ,end ,text) (roost--note-anchor note))
                 (same (seq-filter (lambda (line) (and (eq (nth 1 line) side) (equal (nth 3 line) text)))
                                   lines))
                 (exact (seq-filter (lambda (line) (= (nth 2 line) end)) same))
                 (nearest (car (sort same (lambda (a b) (< (abs (- (nth 2 a) end))
                                                           (abs (- (nth 2 b) end))))))))
      (mapcar (lambda (line) (save-excursion (goto-char (car line)) (line-end-position)))
              (or exact (and nearest (list nearest)))))))

(defun roost--note-overlay (position notes)
  "An overlay showing NOTES after the line ending at POSITION.
It holds the line's newline, so the notes fold away with the line.
Thin rules in the notes' color set each note apart from the diff."
  (let* ((overlay (make-overlay position (min (1+ position) (point-max))))
         (color (face-foreground 'roost-note nil t))
         (last (car (last notes)))
         (text (mapconcat
                (lambda (note)
                  (let ((lines (split-string (with-temp-buffer
                                               (insert (alist-get 'text note))
                                               (let ((fill-column 72))
                                                 (fill-region (point-min) (point-max)))
                                               (buffer-string))
                                             "\n")))
                    (propertize
                     (mapconcat
                      (lambda (line)
                        ;; A rule over each note, and one under the last.
                        (let ((rule (when color
                                      (append (when (eq line (car lines)) `(:overline ,color))
                                              (when (and (eq note last) (eq line (car (last lines))))
                                                `(:underline (:color ,color :position t)))))))
                          ;; The note's own faces, rather than those of the
                          ;; diff line it is shown before.
                          ;; The same in every frame showing the buffer: a
                          ;; terminal may draw no rule over the note, but
                          ;; shows its color and the one under it.
                          (concat (propertize "    " 'face `(,rule (:slant normal) roost-note default))
                                  (propertize line 'face `(,rule roost-note default))
                                  ;; Rules go across the window, as the note's
                                  ;; background does, whatever the next line is.
                                  ;; Not in a text frame, which keeps the last
                                  ;; column for its sign that a line runs on: a
                                  ;; space up to the edge showed a $ there.
                                  (when rule
                                    (propertize " " 'display '(when (display-graphic-p) . (space :align-to right))
                                                'face `(,rule roost-note default)))
                                  (propertize "\n" 'face '(:inherit (roost-note default) :extend t)))))
                      lines "")
                     'roost-note-id (alist-get 'id note)
                     'keymap roost--note-shown-map
                     'mouse-face 'highlight
                     'pointer 'hand
                     'help-echo "mouse-1: edit, send or discard this note")))
                notes "")))
    (overlay-put overlay 'roost-notes notes)
    (overlay-put overlay 'after-string text)
    overlay))

(defun roost--note-room-overlay (position height window)
  "An overlay leaving HEIGHT pixels for the note box, under the line at POSITION.
POSITION is the line's end.  The room comes after the line's notes, and
only in WINDOW, where the box is: other windows showing the buffer
leave none."
  (let ((overlay (make-overlay (min (1+ position) (point-max)) (min (1+ position) (point-max)))))
    (overlay-put overlay 'roost-note-box height)
    (overlay-put overlay 'roost-note-anchor position)
    (overlay-put overlay 'window window)
    (overlay-put overlay 'before-string
                 (concat (propertize " " 'display `(space :width (1) :height (,height))) "\n"))
    overlay))

(defun roost--show-notes-here (task)
  "Show TASK's review notes in this Magit buffer, under their lines.
When the note box was opened from here, leave room for it under its line,
in place of the note it edits."
  (mapc #'delete-overlay roost--note-overlays)
  (setq roost--note-overlays nil)
  (let* ((box (and (eq (plist-get roost--note-box :source) (current-buffer))
                   (plist-get roost--note-box :frame)
                   roost--note-box))
         (notes (and task (remq (plist-get box :old) (roost--task-notes task)))))
    (when (and (or notes box) (bound-and-true-p magit-root-section))
      ;; All of them, though the buffer is narrowed.
      (save-restriction
        (widen)
        (let ((files (roost--magit-file-lines)) shown room)
          (dolist (note notes)
            (when-let* ((entry (assoc (alist-get 'file note) files)))
              (dolist (position (roost--note-positions note (nth 1 entry) (nth 2 entry)))
                (push note (alist-get position shown)))))
          (pcase-dolist (`(,position . ,notes) shown)
            (push (roost--note-overlay position (reverse notes)) roost--note-overlays))
          ;; The box goes after the notes already under its line.
          (when-let* ((place (plist-get box :place))
                      (entry (assoc (alist-get 'file place) files)))
            ;; The copy the box was opened at, of a note shown more than once.
            (let ((positions (roost--note-positions place (nth 1 entry) (nth 2 entry))))
              (setq room (or (nth (or (plist-get box :copy) 0) positions) (car positions))))
            (when room
              (push (roost--note-room-overlay room (plist-get box :room) (plist-get box :window))
                    roost--note-overlays))))))))

(defun roost--map-sections (function &optional section)
  "Call FUNCTION with each section of this Magit buffer, or of SECTION.
A section's children before it, as `magit-map-sections' has it, which
Magit 3 is without."
  (if (fboundp 'magit-map-sections)
      (magit-map-sections function section)
    (when-let* ((section (or section magit-root-section)))
      (dolist (child (roost--slot section 'children))
        (roost--map-sections function child))
      (funcall function section))))

(defun roost--magit-file-lines ()
  "For each file in this Magit buffer's diffs, (FILE HEADINGS LINES).
HEADINGS are the ends of its headings, and LINES its lines, from
`roost--hunk-lines'."
  (let (files)
    (roost--map-sections
     (lambda (section)
       (when (magit-section-match '(file hunk) section)
         (let* ((hunk (magit-section-match 'hunk section))
                (file (roost--slot (if hunk (roost--slot section 'parent) section) 'value))
                (entry (or (assoc file files) (car (push (list file nil nil) files)))))
           (if hunk
               (setf (nth 2 entry) (append (nth 2 entry) (roost--hunk-lines section)))
             (push (save-excursion (goto-char (roost--slot section 'start)) (line-end-position))
                   (nth 1 entry)))))))
    files))

(defun roost--note-copy (place)
  "Which of the places this Magit buffer shows PLACE is nearest point.
A note on a whole file shows under each of its headings, as when it is
both staged and unstaged.  The result indexes `roost--note-positions'."
  (save-restriction
    (widen)
    (when-let* (((bound-and-true-p magit-root-section))
                (entry (assoc (alist-get 'file place) (roost--magit-file-lines)))
                (positions (roost--note-positions place (nth 1 entry) (nth 2 entry))))
      (let* ((here (line-end-position))
             (nearest (car (sort (copy-sequence positions)
                                 (lambda (a b) (< (abs (- a here)) (abs (- b here))))))))
        (seq-position positions nearest)))))

(defun roost--show-notes-everywhere ()
  "Show the current review notes in every Magit buffer on a task."
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'roost-magit-mode buffer)
      (with-current-buffer buffer
        (roost--show-notes-here (roost--task-in-directory default-directory))))))

(defun roost--notes-at-point ()
  "The review notes shown under the line at point."
  (seq-mapcat (lambda (overlay) (overlay-get overlay 'roost-notes))
              (overlays-in (line-end-position) (1+ (line-end-position)))))

(defun roost--random-id ()
  "A new identifier of 16 hex digits, as for a review note."
  (format "%08x%08x" (random (ash 1 32)) (random (ash 1 32))))

;;;###autoload
(defun roost-note ()
  "Write a note for the agent on the diff line at point, or the region's lines.
A region stays within one hunk.  On a file's name the note is about the
whole file, and on a hunk's heading about the whole hunk.  On a line
already noted, edit its note.  You write the note in a box that opens
under its line: \\<roost-note-box-mode-map>\\[roost-note-box-save] saves it, and saving it empty removes it.
With the mouse, click the + that shows beside a diff line, or drag
along lines from there, and click a note to edit it.  Notes show under
their lines in Magit, and go to the agent with your next prompt to it:
\\<roost-magit-mode-map>\\[roost-send] opens one."
  (interactive)
  (unless (derived-mode-p 'magit-mode)
    (user-error "Write notes in Magit, on a task's changes"))
  (roost--magit-setup)
  (let ((task (or (roost--task-in-directory default-directory)
                  (user-error "This repository is not a Roost task's worktree"))))
    ;; A note being written elsewhere is kept, before looking for the
    ;; note here, which it may be.
    (roost--note-box-set-aside)
    (let* ((shown (unless (use-region-p) (roost--notes-at-point)))
           (place (roost--magit-note-place))
           (old (seq-find
                 (lambda (note)
                   (and (equal (roost--note-key note) (roost--key task))
                        (or (seq-every-p (lambda (field)
                                           (equal (alist-get field note) (alist-get field place)))
                                         '(file line end removed))
                            ;; The one note shown here, though its line has moved.
                            (and (not (cdr shown))
                                 (equal (alist-get 'id note) (alist-get 'id (car shown)))))))
                 (roost--notes))))
      (deactivate-mark)
      (roost--note-box task place old))))

(defun roost--note-task-live-p (task)
  "Whether Roost still has TASK, which notes can then be for."
  (and (gethash (roost--key task) roost--tasks) t))

(defun roost--note-save (task place old text)
  "Save TEXT as TASK's note on PLACE, or as note OLD's new text.
Empty TEXT removes OLD.  A task Roost no longer has, as one retired
while you wrote, gets no note."
  (unless (roost--note-task-live-p task)
    (user-error "Roost no longer has %s, so the note can't be kept" (roost--field task 'name)))
  (setq text (string-trim text))
  (roost--notes-as-on-file)
  ;; OLD may have been sent, or discarded, while you wrote.
  (unless (memq old (roost--notes)) (setq old nil))
  (cond ((and old (string-empty-p text))
         (roost--remove-notes (lambda (note) (eq note old))))
        ((string-empty-p text))
        (old (roost--edit-note old text))
        (t
         (setq roost--notes
               (append (roost--notes)
                       (list (append `((id . ,(roost--random-id))
                                       (host . ,(roost--field task 'host))
                                       (task . ,(roost--field task 'id)))
                                     ;; PLACE may be a note that has gone since:
                                     ;; only what that was about.
                                     (seq-remove (lambda (field)
                                                   (memq (car-safe field) '(id host task text)))
                                                 place)
                                     `((text . ,text))))))
         (roost--save-notes)))
  (roost--show-notes-everywhere)
  (roost--redraw)
  (let ((count (length (roost--task-notes task))))
    (message "%s" (substitute-command-keys
                   (if (zerop count)
                       (format "%s has no review notes" (roost--field task 'name))
                     (format "%d review note%s for %s; \\<roost-magit-mode-map>\\[roost-send] sends %s"
                             count (if (= count 1) "" "s") (roost--field task 'name)
                             (if (= count 1) "it" "them")))))))

;;;; The note box

(defface roost-note-box-header '((t :inherit (roost-dim default)))
  "The heading of the box where you write a review note.")

(defface roost-note-box-button
  '((t :inherit default :box (:line-width (6 . 1) :style flat-button)))
  "Buttons in the heading of the note box.")

(defface roost-note-box-default-button
  '((t :inherit roost-note-button :inverse-video t
        :box (:line-width (6 . 1) :style flat-button)))
  "The button saving the note, in the heading of the note box.")

(defvar roost-note-box-lines 4
  "How many lines of text the box for writing a review note shows.")

(defvar-keymap roost-note-box-mode-map
  :doc "Keys for writing a review note."
  "C-c C-c" #'roost-note-box-save
  "C-c C-k" #'roost-note-box-cancel)

(define-derived-mode roost-note-box-mode text-mode "Roost Note"
  "Write a review note for the agent; see `roost-note'.
\\{roost-note-box-mode-map}"
  (setq-local mode-line-format nil
              face-remapping-alist (append '((header-line . roost-note-box-header)
                                             (header-line-active . roost-note-box-header)
                                             (header-line-inactive . roost-note-box-header))
                                           face-remapping-alist))
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'roost--note-box-killed nil t)
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-note-box-mode 'insert)
  (roost--quiet-display))

(defun roost--note-box (task place old)
  "Open the box for writing TASK's note on PLACE, or editing note OLD.
It opens under the line, from the selected window: in a child frame,
over room left for it, where Emacs shows them, or in a window below."
  (let ((buffer (get-buffer-create "*roost note*")))
    (setq roost--note-box (list :buffer buffer :task task :place (or old place) :old old
                                :window (selected-window) :source (current-buffer)
                                :copy (roost--note-copy (or old place))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer))
      (roost-note-box-mode)
      (insert (or (alist-get 'text old) ""))
      (set-buffer-modified-p nil)
      (setq header-line-format '(:eval (roost--note-box-header))))
    (if (display-graphic-p)
        (roost--note-box-float)
      (select-window (display-buffer buffer `((display-buffer-below-selected)
                                              (window-height . ,(+ roost-note-box-lines 2))
                                              (dedicated . t)
                                              (window-parameters . ((tab-line-format . none)))))))
    (message "%s" (substitute-command-keys
                   "\\<roost-note-box-mode-map>\\[roost-note-box-save] saves the note, \\[roost-note-box-cancel] cancels it"))))

(defun roost--header-buttons (buttons)
  "BUTTONS for a header line, each (LABEL COMMAND FACE HELP), as one string.
A click on one runs its COMMAND; HELP goes through `substitute-command-keys'."
  (mapconcat
   (pcase-lambda (`(,label ,command ,face ,help))
     (propertize label 'face face 'mouse-face 'highlight 'pointer 'hand
                 'help-echo (substitute-command-keys help)
                 'local-map (define-keymap "<header-line> <mouse-1>" command)))
   (delq nil buttons)
   " "))

(defun roost--note-box-header ()
  "The heading of the note box: what the note is about, then buttons."
  (let* ((box roost--note-box)
         (old (plist-get box :old))
         (buttons
          (roost--header-buttons
           (list (when old
                   '(" Remove " roost-note-box-remove roost-note-box-button
                     "mouse-1: remove this note"))
                 '(" Cancel " roost-note-box-cancel roost-note-box-button
                   "mouse-1 or \\<roost-note-box-mode-map>\\[roost-note-box-cancel]: close without saving")
                 `(,(if old " Save " " Add note ") roost-note-box-save roost-note-box-default-button
                   "mouse-1 or \\<roost-note-box-mode-map>\\[roost-note-box-save]: save the note")))))
    (when box
      (concat " " (if old "Edit the note on " "Note on ")
              (roost--header-text (roost--note-location (plist-get box :place)))
              (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width buttons)
                                                                         (frame-char-width))))))
              buttons))))

(defun roost--note-box-text ()
  "What the note box holds, or nil when it is closed."
  (when-let* ((buffer (plist-get roost--note-box :buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max)))))

(defun roost-note-box-save ()
  "Save the review note being written; saved empty, it is removed."
  (interactive)
  (let ((box roost--note-box)
        (text (or (roost--note-box-text) (user-error "No note is being written"))))
    ;; Refused with the box still open, so what you wrote is not lost.
    (unless (roost--note-task-live-p (plist-get box :task))
      (user-error "Roost no longer has %s, so the note can't be kept"
                  (roost--field (plist-get box :task) 'name)))
    (roost--note-box-close)
    (roost--note-save (plist-get box :task) (plist-get box :place) (plist-get box :old) text)))

(defun roost-note-box-cancel ()
  "Close the note box without saving."
  (interactive)
  (roost--note-box-close))

(defun roost-note-box-remove ()
  "Remove the review note being edited."
  (interactive)
  (let ((box roost--note-box))
    (roost--note-box-close)
    ;; A task Roost no longer has took its notes with it.
    (when (roost--note-task-live-p (plist-get box :task))
      (roost--note-save (plist-get box :task) (plist-get box :place) (plist-get box :old) ""))))

(defun roost--note-box-close (&optional keep gone)
  "Close the note box.  With KEEP, save the note first if you changed it.
Focus goes back to the Magit window it was opened from.  GONE is the
buffer or frame being killed or deleted already, the box's own or its
frame's parent."
  (when-let* ((box roost--note-box))
    (let ((text (roost--note-box-text))
          (frame (plist-get box :frame))
          (buffer (plist-get box :buffer))
          (window (plist-get box :window))
          (source (plist-get box :source)))
      (setq roost--note-box nil)
      (remove-hook 'window-size-change-functions #'roost--note-box-follow)
      (remove-hook 'window-buffer-change-functions #'roost--note-box-follow)
      (remove-hook 'delete-frame-functions #'roost--note-box-frame-deleted)
      (when (and (frame-live-p frame) (not (eq frame gone))) (delete-frame frame))
      (when (buffer-live-p buffer)
        (dolist (shown (get-buffer-window-list buffer nil t))
          (quit-restore-window shown))
        (unless (eq buffer gone) (kill-buffer buffer)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (remove-hook 'window-scroll-functions #'roost--note-box-follow t)
          (roost--show-notes-here (roost--task-in-directory default-directory))))
      (when (and (window-live-p window) (not (eq (window-frame window) gone)))
        (select-frame-set-input-focus (window-frame window))
        (select-window window))
      ;; Kept as Save would: emptied, a note is removed.  A new note
      ;; left empty, or a note left as it was, stays as it is, and so
      ;; does nothing for a task Roost no longer has.
      (when (and keep text
                 (roost--note-task-live-p (plist-get box :task))
                 (not (equal (string-trim text) (or (alist-get 'text (plist-get box :old)) ""))))
        (roost--note-save (plist-get box :task) (plist-get box :place) (plist-get box :old) text)))))

(defun roost--note-box-set-aside ()
  "Close the note box, keeping what it holds, and stay where you are.
Closing it otherwise selects the window it was opened from."
  (save-excursion
    (let ((window (selected-window)))
      (roost--note-box-close t)
      (when (and (window-live-p window) (not (eq window (selected-window))))
        (unless (eq (window-frame window) (selected-frame))
          (select-frame-set-input-focus (window-frame window)))
        (select-window window)))))

(defun roost--note-box-killed ()
  "Forget the note box when its buffer is killed some other way."
  (when (eq (current-buffer) (plist-get roost--note-box :buffer))
    (roost--note-box-close nil (current-buffer))))

(defun roost--note-box-frame-deleted (frame)
  "Close the note box, keeping what it holds, if FRAME is its frame or the parent.
Run from `delete-frame-functions' while the box is open, as when you
delete its frame with \\[delete-frame]."
  (when-let* ((box-frame (plist-get roost--note-box :frame))
              ((or (eq frame box-frame) (eq frame (frame-parent box-frame)))))
    (with-demoted-errors "Roost: %S"
      (roost--note-box-close t frame))))

(defun roost--note-box-float ()
  "Show the note box in a child frame, over room left under its line."
  (let* ((box roost--note-box)
         (window (plist-get box :window))
         (parent (window-frame window))
         (edges (window-inside-pixel-edges window))
         (numbers (with-selected-window window
                    (if display-line-numbers (line-number-display-width t) 0)))
         (frame (make-frame
                 `((parent-frame . ,parent)
                   (minibuffer . ,(minibuffer-window parent))
                   (name . "Roost note")
                   (visibility . nil)
                   (undecorated . t)
                   (no-other-frame . t)
                   (unsplittable . t)
                   (skip-taskbar . t)
                   (desktop-dont-save . t)
                   (no-special-glyphs . t)
                   (menu-bar-lines . 0)
                   (tool-bar-lines . 0)
                   (tab-bar-lines . 0)
                   (vertical-scroll-bars . nil)
                   (horizontal-scroll-bars . nil)
                   (left-fringe . 8)
                   (right-fringe . 8)
                   (internal-border-width . 0)
                   (child-frame-border-width . 1)
                   (width . (text-pixels . ,(roost--note-box-width window)))
                   (height . ,(+ roost-note-box-lines 1))
                   (left . ,(+ (nth 0 edges) numbers))
                   (top . ,(nth 1 edges)))))
         (root (frame-root-window frame)))
    (set-face-background 'child-frame-border (face-foreground 'shadow nil t) frame)
    ;; The fringes are the box's padding.
    (set-face-background 'fringe (face-background 'default nil t) frame)
    (set-window-buffer root (plist-get box :buffer))
    (set-window-dedicated-p root t)
    ;; Its header line says what it is: a `global-tab-line-mode' tab would
    ;; take a line of its text, and offer the buffers of the window below.
    (set-window-parameter root 'tab-line-format 'none)
    (setq roost--note-box (plist-put (plist-put box :frame frame)
                                     :room (+ (frame-pixel-height frame) 2 8)))
    ;; Room under the line, which then has to be in sight.
    (with-current-buffer (plist-get box :source)
      (add-hook 'window-scroll-functions #'roost--note-box-follow nil t)
      (roost--show-notes-here (plist-get box :task)))
    (add-hook 'window-size-change-functions #'roost--note-box-follow)
    (add-hook 'window-buffer-change-functions #'roost--note-box-follow)
    (add-hook 'delete-frame-functions #'roost--note-box-frame-deleted)
    (unless (roost--note-box-spot)
      (with-selected-window window (recenter 3)))
    (roost--note-box-place)
    (unless (frame-visible-p frame)
      (set-frame-position frame (+ (nth 0 edges) numbers)
                          (max (nth 1 edges) (- (nth 3 edges) (frame-pixel-height frame))))
      (make-frame-visible frame))
    (select-frame-set-input-focus frame)))

(defun roost--note-box-width (window)
  "How wide the note box's text is, in pixels, to span WINDOW's text.
Its fringes and border take 18 pixels more."
  (let ((edges (window-inside-pixel-edges window)))
    (max (* 30 (frame-char-width (window-frame window)))
         (- (nth 2 edges) (nth 0 edges) 18 (frame-char-width (window-frame window))
            (with-selected-window window
              (if display-line-numbers (line-number-display-width t) 0))))))

(defun roost--line-top (position window)
  "The top of the screen line showing POSITION in WINDOW, or nil.
In pixels from the top of WINDOW's text, under any tab and header line.
POSITION may be past the window's right edge, as a long line's end is
where lines are truncated: `posn-at-point' then names the window beside
WINDOW, measuring from its top, or the row below."
  (when-let* ((shown (pos-visible-in-window-p position window t)))
    (- (cadr shown) (window-tab-line-height window) (window-header-line-height window))))

(defun roost--note-box-spot ()
  "Where the note box goes, as pixels in its window's frame, or nil.
It goes over the room left under its line, while that room is in sight
in the window it was opened from."
  (let* ((box roost--note-box)
         (source (plist-get box :source))
         (window (if (and (window-live-p (plist-get box :window))
                          (eq (window-buffer (plist-get box :window)) source))
                     (plist-get box :window)
                   ;; Its buffer may have moved to another window of
                   ;; the frame the box belongs to.
                   (when-let* ((window (get-buffer-window
                                        source (or (frame-parent (plist-get box :frame))
                                                   (selected-frame)))))
                     (setq roost--note-box (plist-put box :window window))
                     window))))
    (when window
      (redisplay)
      (when-let* ((overlay (with-current-buffer source
                             (seq-find (lambda (overlay) (overlay-get overlay 'roost-note-box))
                                       roost--note-overlays)))
                  (room (overlay-get overlay 'roost-note-box))
                  ((progn (overlay-put overlay 'window window) t))
                  (below (roost--line-top (overlay-get overlay 'roost-note-anchor) window))
                  ;; The room is the first row that tall below its line,
                  ;; and has to be in sight whole.  Each row is given by
                  ;; its bottom.
                  (top (let ((top 0) found)
                         (pcase-dolist (`(,_ . ,bottom) (window-lines-pixel-dimensions window nil nil t))
                           (when (and (not found) (> top below) (>= (- bottom top) (- room 2)))
                             (setq found top))
                           (setq top bottom))
                         found)))
        (let ((edges (window-inside-pixel-edges window)))
          (cons (+ (nth 0 edges)
                   (with-selected-window window
                     (if display-line-numbers (line-number-display-width t) 0)))
                (+ (nth 1 edges) top 5)))))))

(defun roost--note-box-place ()
  "Put the note box over the room left for it.
While that room is out of sight, the box is hidden; once the Magit
buffer it came from is gone, it closes, keeping what you wrote."
  (when-let* ((frame (plist-get roost--note-box :frame))
              ((frame-live-p frame)))
    (if (not (buffer-live-p (plist-get roost--note-box :source)))
        (roost--note-box-close t)
      (if-let* ((spot (roost--note-box-spot)))
          (let ((width (roost--note-box-width (plist-get roost--note-box :window))))
            (unless (= width (frame-text-width frame))
              (set-frame-width frame width nil t))
            (set-frame-position frame (car spot) (cdr spot))
            (make-frame-visible frame))
        (when (frame-visible-p frame)
          (when (eq (selected-frame) frame)
            (let ((window (plist-get roost--note-box :window)))
              (when (window-live-p window)
                (select-frame-set-input-focus (window-frame window))
                (select-window window)
                ;; What you type now goes to Magit.
                (message "The note on %s is hidden while its line is out of sight"
                         (roost--note-location (plist-get roost--note-box :place))))))
          (make-frame-invisible frame))))))

(defun roost--note-box-follow (&rest _)
  "Move the note box with its line, once Emacs has redrawn its window.
Run from window hooks, so an error only reports itself."
  (when roost--note-box
    (run-at-time 0 nil (lambda () (with-demoted-errors "Roost: %S" (roost--note-box-place))))))

;;;; Writing notes with the mouse

(defface roost-note-button '((t :inherit link :underline nil :weight bold))
  "The note button beside the diff line under the mouse.
Its foreground fills the button.")

(defvar-local roost--note-hover nil
  "Overlay across this Magit buffer through which Emacs reports the mouse.")
;; Kept when Magit calls its mode again, as `roost--note-overlays' is.
(put 'roost--note-hover 'permanent-local t)
(defvar roost--note-button-images nil
  "The note button's image, made for the colors and sizes in its key.")

(defvar-local roost--note-margin nil
  "A list of the left margin this buffer had before the note button widened it.
Nil while it hasn't; the margin itself can be nil, meaning none.")

(defun roost--note-margin-p ()
  "Whether this Magit buffer shows note buttons, in its left margin.
It does in graphic frames: those showing it, or the selected one before
any does."
  (and roost-magit-mode
       (derived-mode-p 'magit-status-mode 'magit-diff-mode)
       (seq-some (lambda (window) (display-graphic-p (window-frame window)))
                 (or (get-buffer-window-list nil nil t) (list (selected-window))))))

(defun roost--note-hover-setup ()
  "Make room for the note button in this Magit buffer, and follow the mouse.
Emacs calls the help-echo of text as the mouse moves over it, so an
overlay across the buffer has `roost--note-hover-echo' as its help-echo.
A window that shows the buffer later is set up then."
  (let ((on (roost--note-margin-p))
        (had roost--note-margin))
    (if (and roost-magit-mode (derived-mode-p 'magit-status-mode 'magit-diff-mode))
        (add-hook 'window-buffer-change-functions #'roost--note-margins-shown nil t)
      (remove-hook 'window-buffer-change-functions #'roost--note-margins-shown t))
    ;; A margin at least as wide is kept, and the one the buffer had comes
    ;; back once the button is off.
    (cond ((and on (not had))
           (setq roost--note-margin (list left-margin-width)
                 left-margin-width (max (or left-margin-width 0) 2)))
          ((and had (not on))
           (setq left-margin-width (car had)
                 roost--note-margin nil)))
    (dolist (window (get-buffer-window-list nil nil t))
      ;; A text frame shows no button, so its windows keep the margin.
      (let ((left (if (and on (not (display-graphic-p (window-frame window))))
                      (car roost--note-margin)
                    left-margin-width)))
        (unless (eql (car (window-margins window)) left)
          (set-window-margins window left (cdr (window-margins window))))))
    (when (and (overlayp roost--note-button) (eq (overlay-buffer roost--note-button) (current-buffer)))
      (delete-overlay roost--note-button))
    (cond (on
           (unless (overlayp roost--note-hover)
             (setq roost--note-hover (make-overlay (point-min) (point-max) nil nil t))
             (overlay-put roost--note-hover 'help-echo #'roost--note-hover-echo))
           (move-overlay roost--note-hover (point-min) (point-max)))
          ((overlayp roost--note-hover)
           (delete-overlay roost--note-hover)
           (setq roost--note-hover nil)))))

(defun roost--note-margins-shown (window)
  "Set up the note button for WINDOW, if it has started showing this buffer.
The hook runs, with this buffer current, for a window that stopped
showing it too; that one is left alone."
  (when (eq (window-buffer window) (current-buffer))
    (roost--note-hover-setup)))

(defun roost--note-line-start (position)
  "Where the diff line at POSITION starts, if notes can be written on it.
That may be before the narrowing, which can start within the line."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char position)
      (let* ((start (line-beginning-position))
             (section (get-text-property start 'magit-section)))
        (and section
             (magit-section-match 'hunk section)
             (not (roost--slot section 'combined))
             (>= start (roost--slot section 'content))
             (memq (char-after start) '(?+ ?- ?\s))
             start)))))

(defconst roost--note-mouse-interval 0.25
  "Seconds between looks at the mouse while the note button shows.
Once the mouse has rested for 2 seconds, it is looked at once a second.")

(defun roost--note-hover-echo (window object position)
  "Show the note button beside the diff line at POSITION in WINDOW.
Emacs calls this, the help-echo of `roost--note-hover' OBJECT, as the
mouse moves over the text.  It returns the text's own help, if any."
  (when (and (overlayp object) (window-live-p window) (integerp position))
    (with-current-buffer (overlay-buffer object)
      (roost--note-show-button (roost--note-line-start position) window)
      (let ((help (get-text-property position 'help-echo)))
        (and (stringp help) help)))))

(defun roost--note-show-button (start &optional window)
  "Show the note button beside the line starting at START, in WINDOW only.
The line is in the current buffer, which WINDOW shows; with START nil,
hide the button."
  (cond ((not start)
         (when (overlayp roost--note-button) (delete-overlay roost--note-button)))
        (t
         (unless (overlayp roost--note-button)
           (setq roost--note-button (make-overlay start start))
           (delete-overlay roost--note-button))
         (unless (and (eq (overlay-buffer roost--note-button) (current-buffer))
                      (eql (overlay-start roost--note-button) start)
                      (eq (overlay-get roost--note-button 'window) window))
           (overlay-put roost--note-button 'before-string (roost--note-button-string window))
           (overlay-put roost--note-button 'window window)
           (move-overlay roost--note-button start start (current-buffer)))
         (unless (timerp roost--note-mouse-timer)
           (roost--note-watch-mouse roost--note-mouse-interval)))))

(defun roost--note-watch-mouse (interval &optional state)
  "Look at the mouse every INTERVAL seconds, with STATE as it was last seen."
  (when (timerp roost--note-mouse-timer) (cancel-timer roost--note-mouse-timer))
  (setq roost--note-mouse-timer
        (run-with-timer interval interval #'roost--note-follow-mouse
                        (or state (list nil 0)) interval)))

(defun roost--note-follow-mouse (state interval)
  "Move the note button to the diff line under the mouse, or hide it.
Emacs reports the mouse only over text, not past the ends of lines or
outside the window, so this runs every INTERVAL seconds while the button
shows.  STATE holds the mouse's last position and how many looks it has
rested there; while it rests, the looks slow down."
  (let* ((mouse (mouse-pixel-position))
         ;; Outside its frames, Emacs gives the last frame the mouse was
         ;; in, at a place outside it.
         (window (and (cadr mouse) (cddr mouse)
                      (window-at-x-y (cadr mouse) (cddr mouse) (car mouse))))
         (posn (and window (posn-at-x-y (cadr mouse) (cddr mouse) (car mouse))))
         (buffer (and posn (eq (posn-window posn) window) (window-buffer window))))
    (if (equal mouse (car state))
        (cl-incf (cadr state))
      (setcar state mouse)
      (setcar (cdr state) 0))
    (with-current-buffer (or buffer (current-buffer))
      (roost--note-show-button
       (and buffer
            roost--note-hover
            (memq (posn-area posn) '(nil left-margin))
            (posn-point posn)
            (roost--note-line-start (posn-point posn)))
       window))
    (cond ((not (overlay-buffer roost--note-button))
           (cancel-timer roost--note-mouse-timer)
           (setq roost--note-mouse-timer nil))
          ((and (= interval roost--note-mouse-interval) (> (cadr state) 8))
           (roost--note-watch-mouse 1 state))
          ((and (/= interval roost--note-mouse-interval) (zerop (cadr state)))
           (roost--note-watch-mouse roost--note-mouse-interval state)))))

(defun roost--note-button-string (&optional window)
  "The note button, as a string to show in the left margin of WINDOW."
  (propertize "+" 'display `((margin left-margin)
                             ,(if (window-live-p window)
                                  (with-selected-window window (roost--note-button-image))
                                (roost--note-button-image)))
              'help-echo "mouse-1: write a note on this line; drag for more lines"
              'pointer 'hand))

(defun roost--note-button-image ()
  "The note button: a rounded square holding a plus, or text without SVG."
  (if (not (and (display-images-p) (image-type-available-p 'svg) (require 'svg nil t)))
      (propertize "+ " 'face '(:inherit roost-note-button :inverse-video t))
    (let* ((width (* 2 (frame-char-width)))
           (height (default-line-height))
           (fill (roost--svg-colour (or (face-foreground 'roost-note-button nil t) "RoyalBlue")))
           (plus (roost--svg-colour (or (face-background 'default nil t) "white")))
           (key (list width height fill plus)))
      (or (cdr (assoc key roost--note-button-images))
          (let* ((size (min width (- height 2)))
                 (x (/ (- width size) 2.0))
                 (y (/ (- height size) 2.0))
                 (inset (/ size 4.0))
                 (svg (svg-create width height)))
            (svg-rectangle svg x y size size :rx (/ size 4.0) :fill fill)
            (dolist (line `((,(+ x inset) ,(+ y (/ size 2.0)) ,(- (+ x size) inset) ,(+ y (/ size 2.0)))
                            (,(+ x (/ size 2.0)) ,(+ y inset) ,(+ x (/ size 2.0)) ,(- (+ y size) inset))))
              (apply #'svg-line svg (append line (list :stroke plus :stroke-width (/ size 7.0)
                                                       :stroke-linecap "round"))))
            (let ((image (svg-image svg :ascent 'center :pointer 'hand)))
              (push (cons key image) roost--note-button-images)
              image))))))

(defun roost-note-mouse (event)
  "Write a note on the diff line clicked beside, or the lines dragged along.
EVENT is the click or drag, in the left margin of Magit on a task.
Elsewhere, the click moves point, as usual."
  (interactive "e")
  (let* ((start (event-start event))
         (from (posn-point start))
         (to (or (posn-point (event-end event)) from)))
    (select-window (posn-window start))
    (if (not (and from (roost--note-line-start from)))
        (mouse-set-point event)
      (goto-char (min from to))
      (beginning-of-line)
      (if (= (line-number-at-pos from) (line-number-at-pos to))
          (deactivate-mark)
        (push-mark (point) t)
        (activate-mark)
        (goto-char (max from to))
        (end-of-line))
      (roost-note))))

(defun roost-note-mouse-menu (event)
  "Choose what to do with the review note clicked: edit, send or discard it.
EVENT is the click on the note, in Magit."
  (interactive "e")
  (let* ((posn (event-start event))
         (string (posn-string posn))
         (id (and string (get-text-property (cdr string) 'roost-note-id (car string))))
         (note (or (seq-find (lambda (note) (equal (alist-get 'id note) id)) (roost--notes))
                   (user-error "That note has gone"))))
    (select-window (posn-window posn))
    ;; The copy clicked, of a note shown more than once.
    (roost--note-act note event
                     (seq-find (lambda (overlay) (eq (overlay-get overlay 'after-string) (car string)))
                               roost--note-overlays))))

(defun roost-note-actions ()
  "Choose what to do with a review note under the line at point.
It can be edited, sent alone to the agent, or discarded, as clicking it
offers; with more than one note there, first choose which."
  (interactive)
  (unless roost-magit-mode
    (user-error "Use this in Magit, on a task's changes"))
  (let* ((overlay (or (seq-find (lambda (overlay) (overlay-get overlay 'roost-notes))
                                (overlays-in (line-end-position) (1+ (line-end-position))))
                      (user-error "No review note under this line")))
         (notes (overlay-get overlay 'roost-notes))
         (where (let ((top (roost--line-top (line-end-position) (selected-window))))
                  (list (if top
                            ;; A long line's end may be past the window's edge.
                            (list (min (car (pos-visible-in-window-p (line-end-position) nil t))
                                       (window-body-width nil t))
                                  (+ top (default-line-height)))
                          '(0 0))
                        (selected-window))))
         (note (if (not (cdr notes))
                   (car notes)
                 (or (x-popup-menu where `("Review notes"
                                           ("" ,@(mapcar (lambda (note)
                                                           (cons (truncate-string-to-width
                                                                  (car (split-string (alist-get 'text note) "\n"))
                                                                  60 nil nil "…")
                                                                 note))
                                                         notes))))
                     (keyboard-quit)))))
    (roost--note-act note where overlay)))

(defun roost--note-act (note where overlay)
  "Do what is chosen, in a menu at WHERE, with NOTE shown by OVERLAY.
WHERE is a position for `x-popup-menu'."
  (pcase (x-popup-menu where `(,(concat "Note on " (roost--note-location note))
                               ("" ("Edit…" . edit) ("Send to the Agent" . send)
                                "--" ("Discard" . discard))))
    ('edit (roost--note-edit-shown note overlay))
    ('send (roost-note-send note))
    ('discard (roost--note-save (roost--note-task note) note note ""))))

(defun roost--note-task (note)
  "The task NOTE is for."
  (or (gethash (roost--note-key note) roost--tasks)
      (user-error "Roost no longer has the task this note is for")))

(defun roost--note-shown-overlay (note &optional buffer)
  "The overlay showing NOTE in BUFFER, a Magit buffer, if any."
  (with-current-buffer (or buffer (current-buffer))
    (and roost-magit-mode
         (seq-find (lambda (overlay)
                     (seq-some (lambda (shown) (equal (alist-get 'id shown) (alist-get 'id note)))
                               (overlay-get overlay 'roost-notes)))
                   roost--note-overlays))))

(defun roost--note-edit-shown (note &optional overlay)
  "Edit NOTE, shown in this Magit buffer, in the note box under it.
OVERLAY is the one showing it there, if NOTE shows more than once."
  (let ((overlay (or overlay (roost--note-shown-overlay note) (user-error "That note has gone"))))
    (goto-char (overlay-start overlay))
    (beginning-of-line)
    (roost--note-box-set-aside)
    ;; Saving the note being written may have removed this one.
    (when (memq note (roost--notes))
      (roost--note-box (roost--note-task note) note note))))

(defvar roost--notes-sending nil
  "Identifiers of the review notes being sent alone.")

(defun roost-note-send (note)
  "Send review NOTE alone to its task's agent; once sent, it is cleared.
A note edited while it was being sent stays, with your edit.  A note is
sent once at a time."
  (let ((task (roost--note-task note))
        (text (alist-get 'text note))
        (id (alist-get 'id note)))
    (when (member id roost--notes-sending)
      (user-error "Already sending the note on %s" (roost--note-location note)))
    (push id roost--notes-sending)
    (condition-case err
        (roost--send-text
         task (roost--format-note note)
         (lambda (_task)
           (setq roost--notes-sending (delete id roost--notes-sending))
           (when (roost--remove-notes (lambda (shown)
                                        (and (eq shown note) (equal (alist-get 'text shown) text))))
             (roost--redraw))
           (message "Sent the note on %s to %s" (roost--note-location note) (roost--field task 'name)))
         (lambda (err)
           (setq roost--notes-sending (delete id roost--notes-sending))
           (message "Roost could not send the note to %s: %s" (roost--field task 'name) err))
         ;; You have looked at what it is about.
         t
         ;; The same for the same note, and another once you edit it.
         (substring (secure-hash 'sha256 (encode-coding-string (concat id "\0" text) 'utf-8)) 0 16))
      ;; A declined confirmation leaves the note ready to send again.
      ((quit error)
       (setq roost--notes-sending (delete id roost--notes-sending))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun roost-goto-note (&optional task)
  "Go to one of TASK's review notes, chosen in the minibuffer.
The note shows in Magit, under its line, with point on the line:
\\<roost-magit-mode-map>\\[roost-note] there edits it."
  (interactive)
  (setq task (or task (roost--task-in-directory default-directory) (roost--choose)))
  (let* ((notes (or (roost--task-notes task)
                    (user-error "%s has no review notes" (roost--field task 'name))))
         (choices (seq-map-indexed
                   (lambda (note index)
                     (cons (format "%d. %s  %s" (1+ index) (roost--note-location note)
                                   (car (split-string (alist-get 'text note) "\n")))
                           note))
                   notes))
         (note (cdr (assoc (completing-read "Go to note: " (roost--in-order (mapcar #'car choices))
                                            nil t)
                           choices))))
    (roost--goto-note task note)))

(defun roost--goto-note (task note)
  "Show TASK's NOTE in Magit, with point on its line.
A Magit buffer already showing it is used, else Magit's status of the
task's worktree, else a diff of the note's file since the task began.
For a task other than the frame's, its terminal opens first, as
\\[roost-open-task] does."
  (roost--in-task-frame
   task
   (lambda ()
     (let* ((find (lambda ()
                    (seq-find (lambda (buffer) (roost--note-shown-overlay note buffer))
                              (cons (current-buffer)
                                    (seq-filter (lambda (buffer)
                                                  (buffer-local-value 'roost-magit-mode buffer))
                                                (buffer-list))))))
            (buffer (or (funcall find)
                        (progn (roost--magit-status-here task) (funcall find))
                        ;; Committed changes show in the diff since the
                        ;; task's fork point.
                        (progn (roost--diff-file task `((path . ,(alist-get 'file note))))
                               (funcall find))
                        (user-error "The note's line is no longer in the task's changes"))))
       (if-let* ((window (get-buffer-window buffer)))
           (select-window window)
         (pop-to-buffer-same-window buffer))
       (with-current-buffer buffer
         (let ((overlay (roost--note-shown-overlay note)))
           (goto-char (overlay-start overlay))
           ;; Its hunk and file may be folded away.
           (let ((section (magit-current-section)))
             (while section
               (magit-section-show section)
               (setq section (roost--slot section 'parent))))
           (goto-char (overlay-start overlay))
           (beginning-of-line)
           (when (eq (window-buffer) buffer) (recenter))))))))

;;;###autoload
(defun roost-diff-whole-file ()
  "Show the whole of the file at point with its changes marked.
The diff compares what the diff at point compares, such as unstaged
changes, so you can still stage there; select lines to stage only those,
and \\<magit-diff-mode-map>\\[magit-diff-default-context] goes back to the usual hunks.  A new file, with
nothing to compare, opens as it is; stage it from Magit's status."
  (interactive)
  (unless (derived-mode-p 'magit-mode)
    (user-error "Use this in Magit, on a changed file"))
  (let ((file (or (magit-file-at-point) (user-error "Put point on a changed file")))
        (args (seq-remove (lambda (arg) (string-match-p "\\`-U[0-9]*\\'" arg))
                          (car (magit-diff-arguments)))))
    (if (eq (magit-diff-type) 'untracked)
        (find-file (roost--worktree-file file (magit-toplevel)))
      (magit-diff-dwim (cons "-U1000000" args) (list file)))))

;;;###autoload
(defun roost-review (&optional task quit-questions)
  "Open Magit on TASK's worktree, through TRAMP for remote tasks.
Its host first records where the task stands as where you last looked
at it, and Magit's status shows what changed since you looked before.
For a task other than the frame's, its terminal opens first, as
\\[roost-open-task] does, and Magit beside it.  With QUIT-QUESTIONS, as
when you give a command, first quit the questions you left open in the
minibuffer, as `roost-open-task' does."
  (interactive (list nil t))
  (when (and quit-questions (roost--questions-left-open))
    (let ((task (or task (roost--task-at-point))))
      (roost--quit-questions-left-open
       (lambda () (roost-review (or task (roost--read-task "Task: ")))))))
  (setq task (roost--choose task))
  (if (not (require 'magit nil t))
      (roost--magit-status task)
    (roost--look-then task "Magit" #'roost--magit-status)))

(defun roost--look-then (task what show &optional parameters)
  "Record on TASK's host that you look at it now, then call SHOW with TASK.
PARAMETERS go with the request, as `tracked' for a view of the files Git
tracks only, which the host records unless a file it doesn't track is
there.
WHAT names what SHOW shows, for when it doesn't: once you have opened
something else, or gone to another window or buffer, as with
`roost-open-task'.  A host that can't record the look doesn't keep you
from it.  Looking at a task, in Magit or its whole diff, is what Roost
says changed since: see `roost--since-looked'."
  (let* ((generation (cl-incf roost--open-generation))
         (window (if (window-minibuffer-p) (minibuffer-selected-window) (selected-window)))
         (shown (window-buffer window))
         (place (roost--terminal-place shown))
         (frame (window-frame window))
         (key (roost--key task))
         (listed (gethash key roost--tasks))
         (open (lambda (&rest _)
                 (roost--when-out-of-minibuffer
                  (lambda ()
                    (when (= generation roost--open-generation)
                      ;; As it is now: renamed meanwhile, as from another
                      ;; Emacs, its workspace has the new name.
                      (let ((task (gethash key roost--tasks task)))
                        (cond ((roost--went-p key listed)
                               (message "Roost: didn't open %s for %s, as it is no longer listed"
                                        what (roost--field task 'name)))
                              ((not (roost--still-there-p window shown place frame))
                               (message "Roost: didn't open %s for %s, as you went to another window or buffer while its host replied"
                                        what (roost--field task 'name)))
                              (t (funcall show task))))))))))
    (if (gethash (roost--field task 'host) roost--errors)
        (funcall open)
      (roost--look task parameters open))))

(defun roost--look (task parameters then)
  "Record on TASK's host that you look at it now, then call THEN.
PARAMETERS go with the request, as for `roost--look-then'.  THEN gets
the task as its host recorded it, or nil when the host couldn't record
it, as when it doesn't answer, which Roost has said by then."
  (let ((failed (lambda (err)
                  (message "Roost could not record that you looked at %s: %s" (roost--field task 'name) err)
                  (funcall then nil))))
    (if-let* ((err (gethash (roost--field task 'host) roost--errors)))
        (funcall failed err)
      (roost--act task "look" parameters then failed))))

;;;###autoload
(defun roost-mark-looked (&optional task)
  "Record that you have looked at TASK as it stands now, opening nothing.
Its host records where its work stands, files Git doesn't track too, as
`roost-review' does, and what changed since you last looked starts
from there: for a task you judged by its panel, or whose diff you read
in its agent's terminal."
  (interactive)
  (setq task (roost--choose task))
  (roost--look task nil
               (lambda (updated)
                 (when updated
                   (message "Marked %s as looked at" (roost--field updated 'name))))))

(defun roost--magit-status (task)
  "Open Magit's status of TASK's worktree in TASK's frame.
Without Magit, Dired.  See `roost--in-task-frame'."
  (roost--in-task-frame task (lambda () (roost--magit-status-here task))))

(defun roost--magit-status-here (task)
  "Open Magit's status of TASK's worktree now, where you are.
Without Magit, Dired."
  (if (not (require 'magit nil t))
      (dired (roost--remote-directory task))
    (add-hook 'magit-post-refresh-hook #'roost--magit-refreshed)
    (roost--magit-setup)
    (magit-status (roost--remote-directory task))))

(defun roost--measure-task-in (directory)
  "Fetch the Git statistics of the task whose worktree contains DIRECTORY.
Run from other packages' hooks, so an error only reports itself: it
would otherwise stop the functions after this one."
  (with-demoted-errors "Roost: %S"
    (when-let* ((task (roost--task-in-directory directory)))
      (roost--refresh-host (roost--field task 'host) nil (list (roost--field task 'id))))))

(defun roost--magit-refreshed ()
  "Measure the task whose worktree Magit has just refreshed.
Commits and staging there change the task's Git statistics, with no
agent event to prompt a refresh."
  (roost--measure-task-in default-directory))

(defun roost--file-saved ()
  "Measure the task whose worktree holds the file just saved.
An edit not yet staged changes the statistics but not the task's Git
stamp, so polls would not notice it."
  (when buffer-file-name
    (roost--measure-task-in buffer-file-name)))

;;;###autoload
(defun roost-files (&optional task quit-questions)
  "Browse TASK's worktree with Dired.
For a task other than the frame's, its terminal opens first, as
\\[roost-open-task] does.  With QUIT-QUESTIONS, as when you give a
command, first quit the questions you left open in the minibuffer."
  (interactive (list nil t))
  (when (and quit-questions (roost--questions-left-open))
    (let ((task (or task (roost--task-at-point))))
      (roost--quit-questions-left-open
       (lambda () (roost-files (or task (roost--read-task "Task: ")))))))
  (setq task (roost--choose task))
  (roost--in-task-frame task (lambda () (dired (roost--remote-directory task)))))

;;;###autoload
(defun roost-shell (&optional task quit-questions)
  "Open or reuse a shell beside the agent, in TASK's worktree.
With QUIT-QUESTIONS, as when you give a command, first quit the
questions you left open in the minibuffer, as `roost-open-task' does."
  (interactive (list nil t))
  (when (and quit-questions (roost--questions-left-open))
    (let ((task (or task (roost--task-at-point))))
      (roost--quit-questions-left-open
       (lambda () (roost-shell (or task (roost--read-task "Task: ")))))))
  (setq task (roost--choose task))
  (let ((open (roost--while-you-stay task)))
    (roost--act task "shell" nil
                (lambda (updated)
                  (funcall open
                           (lambda ()
                             (roost--display-task updated (roost--field updated 'shellPaneId))
                             (with-current-buffer (window-buffer (selected-window))
                               (unless (tmux-control-tiled-p) (tmux-control-tile))
                               (roost--focus-shell updated roost--open-generation))))))))

(defun roost--focus-shell (task generation)
  "Focus TASK's shell after queued tiling replies, unless GENERATION changed."
  (let ((frame (selected-frame)))
    (tmux-control-query
     "display-message -p '#{window_id}'"
     (lambda (_reply)
       ;; Select outside the process filter, after its buffer/focus restoration.
       (run-at-time
        0.1 nil
        (lambda ()
          (when (and (= generation roost--open-generation)
                     (eq frame (selected-frame))
                     (equal roost--current-task (roost--key task))
                     ;; Opening a file or review while tiling settles cancels
                     ;; the pending terminal focus, even within the same task.
                     (with-current-buffer (window-buffer (selected-window))
                       (and (equal (tmux-control-buffer-host) (roost--field task 'host))
                            (equal (tmux-control-buffer-socket-name) (roost--field task 'socket))
                            (member (tmux-control-active-pane)
                                    (list (roost--field task 'paneId)
                                          (roost--field task 'shellPaneId)))))
                     (or (not (roost--workspace-backend))
                         (equal (roost--current-workspace) (roost--workspace-name task))))
            (when-let* ((window
                         (seq-find
                          (lambda (window)
                            (with-current-buffer (window-buffer window)
                              (and (equal (tmux-control-buffer-host) (roost--field task 'host))
                                   (equal (tmux-control-buffer-socket-name)
                                          (roost--field task 'socket))
                                   (equal (tmux-control-active-pane)
                                          (roost--field task 'shellPaneId)))))
                          (window-list frame))))
              (select-window window)))))))))

;;;###autoload
(defun roost-diff (&optional task quit-questions)
  "Diff TASK's tracked files against where its own work begins.
Its host first records where the task stands as where you last looked
at it, as `roost-review' does, unless a file Git doesn't track is there,
which the diff leaves out.  For a task other than the frame's, its terminal
opens first, as \\[roost-open-task] does, and the diff beside it.  With
QUIT-QUESTIONS, as when you give a command, first quit the questions you
left open in the minibuffer."
  (interactive (list nil t))
  (when (and quit-questions (roost--questions-left-open))
    (let ((task (or task (roost--task-at-point))))
      (roost--quit-questions-left-open
       (lambda () (roost-diff (or task (roost--read-task "Task: ")))))))
  (setq task (roost--choose task))
  (unless (require 'magit nil t)
    (user-error (substitute-command-keys
                 "The diff needs Magit; \\[roost-review] opens the worktree in Dired instead")))
  (roost--magit-setup)
  (let ((show (lambda (task)
                (roost--in-task-frame
                 task (lambda ()
                        (let ((default-directory (roost--remote-directory task)))
                          (magit-diff-working-tree (roost--fork-point task))))))))
    ;; All of its changes, and so a look, as in Magit; but the diff leaves
    ;; out new files, which a look would count as seen, so the host looks
    ;; for them first, rather than trust a list of files that may be old.
    (roost--look-then task "the diff" show '((tracked . t)))))

;;;###autoload
(defun roost-update (&optional task)
  "Merge TASK's integration branch into its worktree.
This brings a task that fell behind up to date before merging it, and
resolves conflicts in the task rather than the primary checkout.  On
conflicts, or changes not yet committed, offer to have the task's
agent do it."
  (interactive)
  (setq task (roost--choose task))
  (let* ((key (roost--key task))
         (listed (gethash key roost--tasks)))
    (roost--act
     task "update" nil
     (lambda (updated)
       (let* ((result (roost--field updated 'update))
              (conflicts (alist-get 'conflicts result))
              (resolved (alist-get 'resolved result))
              (name (roost--field updated 'name))
              (branch (roost--field updated 'integrationBranch)))
         (roost--refresh-host (roost--field updated 'host) nil)
         (cond (conflicts
                (roost--ask-after-reply
                 key listed
                 (lambda ()
                   (if (y-or-n-p (format "%s conflicts with %s in %s.  Ask its agent to resolve them? "
                                         name branch (string-join conflicts ", ")))
                       (roost-send updated
                                   (format "I merged %s into this branch and Git reports conflicts in: %s.%s Resolve the conflicts so the changes from both sides keep working, run the tests, and commit the merge."
                                           branch (string-join conflicts ", ")
                                           (if resolved
                                               (format " It resolved those in %s as they were resolved before (rerere); check them too."
                                                       (string-join resolved ", "))
                                             "")))
                     (message "The merge is in progress in %s's worktree; resolve it in Magit (r) and commit"
                              name)))))
               ;; Git resolved them as you did before (rerere), and left the
               ;; merge to commit.
               (resolved
                (roost--ask-after-reply
                 key listed
                 (lambda ()
                   (if (y-or-n-p (format "%s conflicts with %s in %s, which Git resolved as you resolved them before.  Ask its agent to check them and commit the merge? "
                                         name branch (string-join resolved ", ")))
                       (roost-send updated
                                   (format "I merged %s into this branch. Git reports conflicts in: %s, and resolved them as they were resolved before (rerere), so the merge is staged but not committed. Check that those resolutions keep the changes from both sides working, run the tests, and commit the merge."
                                           branch (string-join resolved ", ")))
                     (message "The merge is in progress in %s's worktree; check it in Magit (r) and commit"
                              name)))))
               ((alist-get 'changed result)
                (message "%s now includes the latest %s" name branch))
               (t (message "%s is already up to date with %s" name branch)))))
     (lambda (err)
       (if (not (string-prefix-p "Commit the task's changes before updating" err))
           (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err)
         (let ((name (roost--field task 'name))
               (branch (roost--field task 'integrationBranch)))
           (roost--ask-after-reply
            key listed
            (lambda ()
              (if (y-or-n-p (format "%s has changes not yet committed.  Ask its agent to commit them and merge %s? "
                                    name branch))
                  (roost-send task
                              (format "Commit your changes, then merge %s into this branch. If that conflicts, resolve the conflicts so the changes from both sides keep working. Run the tests, and commit the merge."
                                      branch))
                (message "%s" (substitute-command-keys
                               (format "Commit %s's changes in Magit (\\<roost-task-info-mode-map>\\[roost-review]), then update it again"
                                       name))))))))))))

;;;; Pull requests

(defvar-local roost--pr-task nil
  "The task a pull request draft will be created for.")
(defvar-local roost--pr-sending nil
  "Non-nil while the drafted pull request is being created.")

(defvar-keymap roost-pr-mode-map
  :doc "Keys for drafting a pull request."
  "C-c C-c" #'roost-pr-submit
  "C-c C-k" #'roost-pr-cancel)

(define-derived-mode roost-pr-mode text-mode "Roost PR"
  "Draft a pull request: the first line is the title, the rest the body.
\\{roost-pr-mode-map}"
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-pr-mode 'insert)
  (roost--quiet-display))

(defun roost--git-output (task &rest args)
  "Output of Git ARGS in TASK's worktree (over TRAMP for remote tasks).
Nil when Git fails."
  (apply #'roost--git-in (roost--remote-directory task) args))

(defun roost--git-in (directory &rest args)
  "Output of Git ARGS in DIRECTORY, on its host.  Nil when Git fails."
  (let ((default-directory directory))
    (ignore-errors
      (with-temp-buffer
        (when (zerop (apply #'process-file "git" nil t nil args))
          (buffer-string))))))

(defun roost--fork-point (task)
  "Commit where TASK's own work begins, as the host helper reckons it.
Updating a task merges its integration branch in and moves the merge base
forward; before that, or when that branch was rewritten, it is the commit
the task started from."
  (let ((base (roost--field task 'baseCommit))
        (integration (roost--field task 'integrationBranch)))
    (or (when-let* ((base)
                    (integration)
                    (output (roost--git-output task "merge-base"
                                               (concat "refs/heads/" integration) "HEAD"))
                    (merged (string-trim output))
                    ((roost--git-output task "merge-base" "--is-ancestor" base merged)))
          merged)
        base)))

(defun roost--pr-commits (task)
  "Messages of TASK's own commits, oldest first, read with Git in its worktree.
Merges, such as updates from the integration branch, and trailers such as
Co-Authored-By are left out.  Nil when Git cannot say."
  (when-let* ((base (roost--fork-point task))
              ;; Without the lines log.showSignature adds before each.
              (output (roost--git-output task "log" "--no-show-signature" "--reverse" "--no-merges"
                                         "--format=%B%x00" (concat base "..HEAD"))))
    (delete "" (mapcar #'roost--without-trailers (split-string output "\0")))))

(defun roost--without-trailers (message)
  "Commit MESSAGE, trimmed, without a final paragraph of trailers.
Trailers have hyphenated keys, such as Co-Authored-By and Signed-off-by."
  (let ((message (string-trim message)))
    (if (string-match "\n\n\\(?:[[:alpha:]]+\\(?:-[[:alnum:]]+\\)+: .*\\(?:\n\\|\\'\\)\\)+\\'" message)
        (string-trim (substring message 0 (match-beginning 0)))
      message)))

(defun roost--readable-name (name)
  "TASK NAME's words as a sentence: \"fix-auth\" becomes \"Fix auth\"."
  (let ((words (string-trim (replace-regexp-in-string "[-_ ]+" " " (or name "")))))
    (if (string-empty-p words) words (concat (upcase (substring words 0 1)) (substring words 1)))))

(defun roost--pr-initial-text (task commits)
  "Draft text for TASK's pull request: a title line, then the body.
COMMITS are the task's commit messages, oldest first.  The first commit
gives the title and body, and later ones, often review fixes, are listed
by subject.  Without commits the title is the task name, and without a
message body the prompt stands in.  A task started from a GitHub issue
closes it, and one from a Jira work item links to it."
  (let* ((subjects (mapcar (lambda (message) (car (split-string message "\n"))) commits))
         (title (or (car subjects) (roost--readable-name (roost--field task 'name))))
         (first-body (and commits (string-trim (substring (car commits) (length (car subjects))))))
         (body (delq nil (list (if (and first-body (not (string-empty-p first-body)))
                                   first-body
                                 (when-let* ((prompt (roost--prompt-text task))) (string-trim prompt)))
                               (when (cdr subjects)
                                 (mapconcat (lambda (subject) (concat "- " subject)) (cdr subjects) "\n")))))
         (issue (alist-get 'number (roost--field task 'issue)))
         (key (alist-get 'key (roost--field task 'issue)))
         (url (alist-get 'url (roost--field task 'issue))))
    ;; Let GitHub close the task's issue when this merges, unless the text
    ;; already says to with one of GitHub's words: the prompt names the
    ;; issue without one.
    (when (and issue (not (let ((case-fold-search t))
                            (string-match-p (format "\\b\\(?:close[sd]?\\|fix\\(?:e[sd]\\)?\\|resolve[sd]?\\):? +#%s\\b"
                                                    issue)
                                            (string-join body "\n")))))
      (setq body (append body (list (format "Closes #%s" issue)))))
    ;; Jira finds the pull request by the key its branch leads with, and
    ;; this way back is for the people reviewing it.
    (when (and key (not (let ((case-fold-search nil))
                          (string-match-p (format "\\b%s\\b" (regexp-quote key)) (string-join body "\n")))))
      (setq body (append body (list (if url (format "Jira: [%s](%s)" key url) (concat "Jira: " key))))))
    (concat title "\n\n" (string-join body "\n\n") (if body "\n" ""))))

(defconst roost--pr-buttons
  '((" Cancel " roost-pr-cancel roost-note-box-button
     "mouse-1 or \\<roost-pr-mode-map>\\[roost-pr-cancel]: discard the pull request")
    (" Create draft " roost-pr-submit-draft roost-note-box-button
     "mouse-1 or C-u \\<roost-pr-mode-map>\\[roost-pr-submit]: create it as a draft")
    (" Create " roost-pr-submit roost-note-box-default-button
     "mouse-1 or \\<roost-pr-mode-map>\\[roost-pr-submit]: create the pull request"))
  "The buttons in a pull request draft's header line.")

(defun roost--pr-header (task)
  "Header line for TASK's pull request draft, before its buttons."
  (substitute-command-keys
   (format " Pull request for %s%s · \\<roost-pr-mode-map>\\[roost-pr-submit] create (C-u: draft) · \\[roost-pr-cancel] cancel"
           (roost--field task 'name)
           (if-let* ((since (roost--since-looked-text task))) (format " (%s)" since) ""))))

(defun roost--pr-draft (task)
  "Open a draft buffer for TASK's pull request.
An existing draft for TASK is reused, and kept as written unless it is empty."
  (let ((buffer (roost--draft-buffer "pr" 'roost--pr-task task)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-pr-mode) (roost-pr-mode))
      (setq roost--pr-task task
            roost--draft-note nil
            header-line-format '(:eval (roost--draft-header (roost--pr-header roost--pr-task)
                                                            roost--pr-buttons roost--pr-sending)))
      (when (string-empty-p (string-trim (buffer-string)))
        (erase-buffer)
        (insert (roost--pr-initial-text task (roost--pr-commits task)))
        (goto-char (point-min))
        (end-of-line)))
    (pop-to-buffer buffer)))

;;;###autoload
(defun roost-pr (&optional task skip-push)
  "Open a pull request for TASK, or push to the one it already has.
Write the title on the first line and the body below it;
\\<roost-pr-mode-map>\\[roost-pr-submit] pushes the branch and creates it.
For a task with a pull request, push its new commits and open it in the
browser; with prefix argument SKIP-PUSH, or once it is merged or closed,
only open it.  One merged or closed that leaves commits to propose takes
no more of them: draft another, unless SKIP-PUSH says only to open it."
  (interactive (list nil current-prefix-arg))
  (setq task (roost--choose task))
  (roost--refuse-conversation task "has no project to propose its work to")
  (if-let* ((pr (roost--field task 'pr))
            (url (alist-get 'url pr))
            ((or skip-push (not (roost--pr-spent-p task)))))
      (if (or skip-push (memq (roost--pr-state task) '(merged closed)))
          (browse-url url)
        (roost--act
         task "pr" nil
         (lambda (updated)
           (let ((pushed (or (alist-get 'pushed updated) 0))
                 (number (roost--pr-number pr))
                 ;; As the task is now: you may have looked during the push.
                 (since (if-let* ((text (roost--since-looked-text updated))) (concat "; " text) "")))
             (if (zerop pushed)
                 (message "Roost: %s is up to date%s" number since)
               (message "Roost: Pushed %d commit%s to %s%s"
                        pushed (if (= pushed 1) "" "s") number since)))
           (browse-url url))))
    (roost--pr-draft task)))

(defun roost--pr-spent-p (task)
  "Whether TASK's commits need another pull request than the one it has.
That one is closed, or merged with commits since, and TASK has commits
to propose, as the next step offers: its host won't from another branch."
  (and (numberp (roost--field task 'ahead)) (> (roost--field task 'ahead) 0)
       (not (roost--other-branch task))
       (pcase (roost--pr-state task)
         ('closed t)
         ('merged (not (roost--landed task))))))

(defun roost-pr-cancel (&optional event)
  "Discard the pull request draft, or the one whose Cancel button EVENT clicked."
  (interactive (list last-nonmenu-event))
  (roost--draft-clicked event 'roost-pr-mode)
  (roost--quit-questions-here #'roost-pr-cancel)
  (when (or (string-empty-p (string-trim (buffer-string)))
            (yes-or-no-p "Discard this pull request? "))
    (quit-window t)))

(defun roost-pr-submit-draft (&optional event)
  "Create the drafted pull request as a draft.
EVENT, a click on the draft's Create draft button, says which draft."
  (interactive (list last-nonmenu-event))
  (roost-pr-submit t event))

(defun roost-pr-submit (&optional draft event)
  "Create the drafted pull request; with prefix argument DRAFT, as a draft.
The text is kept if creation fails.  EVENT, a click on the draft's
Create button, says which draft."
  (interactive (list current-prefix-arg last-nonmenu-event))
  (roost--draft-clicked event 'roost-pr-mode)
  (let* ((text (buffer-string))
         (newline (string-match "\n" text))
         (title (string-trim (if newline (substring text 0 newline) text)))
         (body (if newline (string-trim (substring text newline)) ""))
         (task roost--pr-task)
         (buffer (current-buffer)))
    (when (string-empty-p title)
      (user-error "Write a title on the first line"))
    (when roost--pr-sending
      (user-error "Already creating"))
    ;; Or one of the draft's own, as whether to discard it, would outlive it.
    (roost--quit-questions-here (lambda () (roost-pr-submit draft)))
    (setq roost--pr-sending t
          roost--draft-note nil)
    (message "Roost: creating a pull request for %s…" (roost--field task 'name))
    (condition-case err
        (roost--act
         task "pr" `((title . ,title) (body . ,body) (draft . ,(and draft t)))
         (lambda (updated)
           (let* ((number (roost--pr-number (roost--field updated 'pr)))
                  (said (cond
                         ;; It had one by then, as its agent opened, with words of its own.
                         ((assq 'pushed updated)
                          (format "%s already has %s; pushed to it, and your text stays here"
                                  (roost--field task 'name) number))
                         ;; You went on writing as it went.
                         ((and (buffer-live-p buffer)
                               (not (equal text (with-current-buffer buffer (buffer-string)))))
                          (format "Opened %s before you changed this; all of it is still here" number)))))
             (if (not said)
                 (progn
                   (roost--close-buffer buffer)
                   (message "Roost: opened pull request %s %s" number
                            (alist-get 'url (roost--field updated 'pr))))
               (message "Roost: %s" said)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq roost--pr-sending nil
                         roost--draft-note (concat " " said))
                   (force-mode-line-update))))))
         (lambda (err)
           (message "Roost could not create the pull request: %s" err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq roost--pr-sending nil)
               (roost--draft-error "Could not create" err 'roost-pr-submit)))))
      ;; Nothing reached the host, as for a byte in a commit quoted there.
      ((quit error)
       (setq roost--pr-sending nil)
       (signal (car err) (cdr err))))))

(defun roost--worktree-pr (task)
  "The pull request from the branch TASK's worktree is on, when not the task's.
As after its agent made a branch there to follow a team's naming,
pushed it and opened one from it: as GitHub was last asked, while the
worktree is still on that branch.  Nil otherwise."
  (when-let* ((pr (roost--field task 'worktreePr))
              ((consp pr))
              (branch (roost--other-branch task))
              ((equal (alist-get 'branch pr) branch)))
    pr))

(defun roost--pr-view (task)
  "TASK as the views of its pull request take it.
While its worktree is on another branch with a pull request, that one
stands in for the task's own, which acts on the task's branch: the
work is there.  The commits it lacks are as GitHub was last asked,
unknown once that branch has moved."
  (if-let* ((pr (roost--worktree-pr task)))
      `((pr . ,pr) (prStatus . ,pr)
        ,@(when (equal (alist-get 'state pr) "OPEN")
            `((unpushed . ,(and (equal (alist-get 'tip pr) (roost--field task 'worktreeHead))
                                (alist-get 'unpushed pr)))))
        ,@(assq-delete-all 'unpushed (copy-sequence task)))
    task))

(defun roost--forge-name (record)
  "The forge RECORD, a pull request or an issue, is on: \"GitLab\" or \"GitHub\".
Records from older hosts are all GitHub's."
  (if (equal (alist-get 'forge record) "gitlab") "GitLab" "GitHub"))

(defun roost--pr-number (pr)
  "PR by number, as its forge writes it: \"#12\" on GitHub, \"!12\" on GitLab."
  (format "%s%s" (if (equal (alist-get 'forge pr) "gitlab") "!" "#") (alist-get 'number pr)))

(defun roost--pr-name (task)
  "TASK's pull request, as `roost--pr-view' has it, by number, as \"#12\".
The branch its worktree is on follows, as \"#12 from feat\", for that
branch's."
  (let ((pr (roost--field (roost--pr-view task) 'pr)))
    (concat (roost--pr-number pr)
            (when-let* ((branch (alist-get 'branch pr))) (concat " from " branch)))))

(defun roost--worktree-merged-p (task)
  "Whether a pull request merged all of the branch TASK's worktree is on.
As GitHub was last asked, and the worktree last measured."
  (when-let* ((pr (roost--worktree-pr task)))
    (and (equal (alist-get 'state pr) "MERGED")
         (equal (alist-get 'head pr) (roost--field task 'worktreeHead)))))

(defun roost--pr-state (task)
  "TASK's pull request state: `open', `draft', `merged', `closed', or nil.
Without a status from GitHub yet, it is as its host recorded, or open."
  (when-let* ((pr (roost--field task 'pr)))
    (let ((status (or (roost--field task 'prStatus) (and (alist-get 'state pr) pr))))
      (cond ((not status) 'open)
            ((equal (alist-get 'state status) "MERGED") 'merged)
            ((equal (alist-get 'state status) "CLOSED") 'closed)
            ((alist-get 'draft status) 'draft)
            (t 'open)))))

(defun roost--pr-face (state)
  "Face for pull request STATE."
  (pcase state
    ('draft 'roost-pr-draft) ('merged 'roost-pr-merged) ('closed 'roost-pr-closed)
    (_ 'roost-pr-open)))

(defun roost--pr-checks (task)
  "TASK's check counts as (PASSING FAILING PENDING), or nil if unknown or none."
  (when-let* ((checks (alist-get 'checks (roost--field task 'prStatus))))
    (let ((counts (mapcar (lambda (key) (or (alist-get key checks) 0))
                          '(passing failing pending))))
      (when (> (apply #'+ counts) 0) counts))))

(defconst roost--pr-settle 30
  "Seconds after an agent's last event before GitHub's word counts.
GitHub asked about its pull request sooner may not know of a push at the
end of its turn, nor of the checks that push starts.")

(defconst roost--pr-grace 120
  "Seconds a failed check or an unresolved review thread is left to the agent.
An agent that watches its own pull request starts a turn by then.")

(defun roost--time (timestamp)
  "TIMESTAMP, in ISO 8601, as a Lisp time; nil if missing or unreadable.
To the fraction of a second hosts record, which `date-to-time' drops:
an agent's event can follow a look in the same second."
  (when (stringp timestamp)
    (or (ignore-errors (encode-time (iso8601-parse timestamp t)))
        (ignore-errors (date-to-time timestamp)))))

(defun roost--pr-status (task)
  "What GitHub last said of TASK's open pull request, if it covers its work.
That is when its agent neither works nor asks, and GitHub was asked
`roost--pr-settle' seconds or more after the agent's last event, so it
knew of every push the agent made.  Its head is the one TASK's host
records, which another Emacs's lookup may have moved on, as the commits
the pull request lacks are counted from it.  Nil otherwise.  As
`roost--pr-view' has it."
  (when-let* ((task (roost--pr-view task))
              (status (roost--field task 'prStatus))
              ((equal (alist-get 'state status) "OPEN"))
              ((equal (alist-get 'head status) (alist-get 'head (roost--field task 'pr))))
              ((not (member (roost--status-name task) '("starting" "running" "background" "permission"))))
              (checked (roost--time (alist-get 'checkedAt status)))
              ((let ((updated (roost--time (roost--field task 'updatedAt))))
                 (or (not updated) (time-less-p (time-add updated roost--pr-settle) checked)))))
    status))

(defun roost--pr-verdict (task &optional patient)
  "What TASK's open pull request waits on you for, as GitHub last said, or nil.
\"ci failed\" when a check failed; \"comments\" when a review thread is
unresolved, its agent's reply in it or not; \"to merge\" when every check
passed, no review is still asked for, none requested changes, and GitHub
finds no conflicts, and doesn't say branch rules block it or it needs
updating.  Only as `roost--pr-status' has it, and while the
pull request has every commit of the task's, with none left uncommitted
nor in its agent's own worktrees.  PATIENT leaves a failure or thread to
the agent for `roost--pr-grace' seconds after it came.  As
`roost--pr-view' has it: the pull request from the branch its worktree
is on, while there is one."
  (when-let* ((task (roost--pr-view task))
              (status (roost--pr-status task))
              ((eql (roost--field task 'unpushed) 0))
              ((not (roost--field task 'dirty)))
              ((not (roost--field task 'merging)))
              ((not (roost--agent-work-left task))))
    (let* ((checks (alist-get 'checks status))
           (failing (alist-get 'failing checks))
           (threads (alist-get 'threads status))
           (due (lambda (field)
                  (let ((seconds (roost--seconds-since (alist-get field status))))
                    ;; Without a time, which gh may leave out, at once.
                    (or (not patient) (not seconds) (>= seconds roost--pr-grace))))))
      (cond ((and (numberp failing) (> failing 0) (funcall due 'failedAt)) "ci failed")
            ((and (numberp threads) (> threads 0) (funcall due 'threadAt)) "comments")
            ((and checks (eql failing 0) (eql (alist-get 'pending checks) 0) (eql threads 0)
                  (assq 'requested status) (null (alist-get 'requested status))
                  (not (member (alist-get 'review status) '("CHANGES_REQUESTED" "REVIEW_REQUIRED")))
                  (equal (alist-get 'mergeable status) "MERGEABLE")
                  (not (member (alist-get 'mergeState status) '("BLOCKED" "BEHIND"))))
             "to merge")))))

(defun roost--pr-turn (task)
  "TASK's status while its pull request waits on you, or nil.
One of `roost--pr-turns', from `roost--pr-verdict' giving its agent time
to take up a failure or thread, once you have seen what the agent last
did, as for one merged: stopped too, its host keeps it seen only if it
was before.  It lasts until the pull request or the agent moves: seeing
it changes nothing, as it does nothing to the pull request."
  (when (roost--seen-p task)
    (roost--pr-verdict task t)))

(defun roost--turn (task)
  "What of TASK's pull request or work waits on you, as its status word, or nil.
One of `roost--pr-turns' or \"conflicts\", as `roost--display-status'
has it.  Its host notes it, for `roost-workload'."
  (unless (roost--merged-p task)
    (or (roost--pr-turn task) (and (roost--conflict-turn task) "conflicts"))))

(defun roost--judged-p (task)
  "Whether what of TASK waits on you can be told yet.
That is once its host has measured it, which a list with its pull
requests but not its Git statistics hasn't, and GitHub has said how its
open pull request is, its reviews too: the one `roost--pr-view' has."
  (let* ((view (roost--pr-view task))
         (status (roost--field view 'prStatus)))
    (and (assq 'conflicts task)
         (or (not (memq (roost--pr-state view) '(open draft)))
             (and status (not (and (alist-get 'reviewsFailed status) (not (assq 'mergeable status))))))
         t)))

(defun roost--report-turn (task)
  "Tell TASK's host when `roost--turn' changes for it, as its record has it.
Only Emacs asks GitHub, and judges what it says: the host's history
notes it beside what the agent did.  Not until `roost--judged-p', or a
turn it had would seem to end."
  (let ((key (roost--key task))
        (turn (roost--turn task)))
    (cond ((equal turn (roost--field task 'turn)) (remhash key roost--turns-sent))
          ((equal turn (gethash key roost--turns-sent 'none)))
          ((roost--judged-p task)
           (puthash key turn roost--turns-sent)
           (let ((sent (lambda ()
                         (when (equal (gethash key roost--turns-sent 'none) turn)
                           (remhash key roost--turns-sent)))))
             ;; Nor must a report stop the reply it came of: not sent at all,
             ;; as with no helper to read, it is sent again too.
             (condition-case nil
                 (roost--request (roost--field task 'host) "turn"
                                 (list (cons 'id (roost--field task 'id)) (cons 'turn turn))
                                 ;; What its record says now, which another Emacs
                                 ;; may yet change: the next poll compares again.
                                 (lambda (record)
                                   (funcall sent)
                                   (when-let* ((cached (gethash key roost--tasks)))
                                     (puthash key (cons (cons 'turn (roost--field record 'turn))
                                                        (assq-delete-all 'turn (copy-sequence cached)))
                                              roost--tasks)))
                                 ;; Sent again with the task's next news.
                                 (lambda (_) (funcall sent)))
               (error (funcall sent))
               (quit (funcall sent) (signal 'quit nil))))))))

(defun roost--reviewer-name (reviewer)
  "How to name REVIEWER, a login or team slug that a review is asked of.
GitHub's GraphQL API names Copilot's reviewer by its bot's login."
  (if (member (downcase reviewer) '("copilot" "copilot-pull-request-reviewer")) "Copilot" reviewer))

(defun roost--pr-reason (task verdict)
  "Why TASK's pull request waits on you for VERDICT, from `roost--pr-verdict'."
  (let* ((task (roost--pr-view task))
         (status (roost--field task 'prStatus))
         (number (roost--pr-name task))
         (count (lambda (n what) (format "%d %s%s" n what (if (= n 1) "" "s")))))
    (pcase verdict
      ("ci failed"
       (let ((failing (alist-get 'failing (alist-get 'checks status))))
         (if (= failing 1)
             (format "A check failed on %s" number)
           (format "%d checks failed on %s" failing number))))
      ("comments" (format "%s has %s" number (funcall count (alist-get 'threads status) "unresolved review thread")))
      (_ (format "%s%s passed its checks and review" (if (alist-get 'draft status) "Draft " "") number)))))

(defun roost--pr-next-step (task key)
  "What to do next with TASK's open pull request, naming keys with KEY.
KEY is a function that formats a key, as in `roost--next-step'.
For the pull request from the branch its worktree is on, which `P'
would not push to, nor open, what to do on GitHub, or with that branch."
  (let* ((task (roost--pr-view task))
         (status (roost--pr-status task))
         (number (roost--pr-name task))
         (branch (alist-get 'branch (roost--field task 'pr)))
         (open (unless branch (concat ", " (funcall key "P") " opens it")))
         (unpushed (and status (roost--field task 'unpushed)))
         (verdict (roost--pr-verdict task))
         (tell (if (roost--agent-running-p task)
                   (concat (funcall key "e") " tells its agent")
                 (concat (funcall key "s") " resumes its agent")))
         (pending (alist-get 'pending (alist-get 'checks status)))
         (reviewers (mapcar #'roost--reviewer-name (alist-get 'requested status)))
         (waits (delq nil (list (when (and (numberp pending) (> pending 0))
                                  (format "%d check%s" pending (if (= pending 1) "" "s")))
                                (when reviewers
                                  (if (cdr reviewers)
                                      (concat "reviews from " (string-join reviewers ", "))
                                    (concat (car reviewers) "'s review")))
                                (pcase (alist-get 'mergeState status)
                                  ("BLOCKED" "branch rules")
                                  ("BEHIND" "an update from the branch it merges into"))))))
    (cond
     (verdict
      (concat (roost--pr-reason task verdict) ": "
              (pcase verdict
                ("to merge" (if branch
                                (concat "merge it on " (roost--forge-name (roost--field task 'pr)))
                              (concat (funcall key "P") " opens it to merge")))
                ("comments" (concat tell " to answer them" open))
                (_ (concat tell open)))))
     ((and (numberp unpushed) (> unpushed 0))
      (if branch
          (format "%s lacks %d new commit%s: push %s to add them" number unpushed (if (= unpushed 1) "" "s") branch)
        (format "%s pushes %d new commit%s to %s" (funcall key "P") unpushed (if (= unpushed 1) "" "s") number)))
     ((and status (equal (alist-get 'mergeable status) "CONFLICTING"))
      (format "%s conflicts with the branch it merges into: %s%s" number tell (or open "")))
     ((and status (eql unpushed 0) waits)
      (format "%s waits for %s" number (string-join waits " and ")))
     (branch (roost--other-branch-step task key))
     ;; As after a push, which GitHub is yet to be asked about.
     ((eql (roost--field task 'unpushed) 0)
      (format "%s has every commit of the task's: %s opens it" number (funcall key "P")))
     (t (concat (funcall key "P") " pushes new commits to its pull request")))))

(defun roost--conflicts (task)
  "Whether TASK's work conflicts with the branch it merges into, or nil.
For an open pull request, t when GitHub said so, as `roost--pr-status'
has it, while the pull request has every commit of the task's.
Otherwise the files in which merging its committed work would conflict,
as its host last measured them, unless that work is merged.  As
`roost--pr-view' has it."
  (setq task (roost--pr-view task))
  (if (memq (roost--pr-state task) '(open draft))
      (when-let* ((status (roost--pr-status task))
                  ((eql (roost--field task 'unpushed) 0)))
        (equal (alist-get 'mergeable status) "CONFLICTING"))
    (unless (roost--landed task)
      (roost--field task 'conflicts))))

(defun roost--conflicting-p (task)
  "Whether TASK's work conflicts with the branch it merges into, as it stands.
That is while its agent neither works, asks nor failed, with nothing
left uncommitted or in its agent's own worktrees, nor a merge under
way: until then those come first."
  (and (not (member (roost--status-name task)
                    '("starting" "running" "background" "permission" "error" "failed" "crashed")))
       (not (roost--field task 'dirty))
       (not (roost--field task 'merging))
       (not (roost--agent-work-left task))
       (roost--conflicts task)
       t))

(defun roost--conflict-turn (task)
  "Whether TASK's work conflicts with the branch it merges into, for you.
That is as `roost--conflicting-p' has it, once you have seen what its
agent last did."
  (and (roost--seen-p task) (roost--conflicting-p task)))

(defun roost--news-turn (task)
  "What of TASK's pull request or work waits on you, for a notification, or nil.
As `roost--turn' has it, but whether or not you have seen what its agent
last did: a notification about it is news."
  (or (roost--pr-verdict task t) (and (roost--conflicting-p task) "conflicts")))

(defun roost--conflict-reason (task)
  "What TASK's work conflicts with, on one line, or nil."
  (let ((conflicts (roost--conflicts task)))
    (cond ((consp conflicts)
           (format "Conflicts with %s in %s" (or (roost--field task 'integrationBranch) "its branch")
                   (roost--file-list conflicts)))
          (conflicts
           (format "%s conflicts with the branch it merges into" (roost--pr-name task))))))

(defun roost--turn-reason (task turn)
  "Why TASK's pull request or work waits on you for TURN, as `roost--turn' has it."
  (if (equal turn "conflicts")
      (roost--conflict-reason task)
    (roost--pr-reason task turn)))

(defun roost--file-list (files &optional most)
  "FILES joined for a sentence: the first MOST, 3 by default, and how many more."
  (let* ((most (or most 3))
         (shown (seq-take files most))
         (more (- (length files) (length shown))))
    (concat (string-join shown ", ")
            (when (> more 0) (format " and %d more" more)))))

(defun roost--changing-text (changing one many &optional name)
  "One line naming the tasks in CHANGING, as `roost--changing' gives them.
The first three by name, the rest counted, with their names and files on
hover; then ONE, or MANY for more than one task, and their files.  NAME
makes a task's name, a string, as a button; the task's name by default.
One line, however many tasks: where every task changes a file, as a
changelog, a line for each would bury the rest."
  (let* ((named (mapcar (lambda (overlap)
                          (if name (funcall name (car overlap)) (roost--field (car overlap) 'name)))
                        (seq-take changing 3)))
         (rest (nthcdr 3 changing))
         (files (seq-uniq (apply #'append (mapcar #'cdr changing)))))
    (concat (cond (rest (concat (string-join named ", ") " and "
                                (propertize (format "%d more" (length rest))
                                            'help-echo (mapconcat (lambda (overlap)
                                                                    (format "%s changes %s"
                                                                            (roost--field (car overlap) 'name)
                                                                            (roost--file-list (cdr overlap))))
                                                                  rest "\n"))))
                  ((cdr named) (concat (string-join (butlast named) ", ") " and " (car (last named))))
                  (t (car named)))
            " " (if (cdr changing) many one) " " (roost--file-list files))))

(defun roost--unmerged-files (task)
  "The paths of TASK's changed files, as its host last listed them.
Of a task whose commits are merged, only those it changes since."
  (let ((landed (roost--landed task)))
    (seq-keep (lambda (file)
                (when (or (not landed) (alist-get 'uncommitted file) (alist-get 'untracked file))
                  (alist-get 'path file)))
              (roost--field task 'files))))

(defun roost--overlaps (task)
  "Other tasks of TASK's project that change files it changes, committed or not.
A list of (OTHER . FILES), as `roost--changing' gives them."
  (when-let* ((files (roost--unmerged-files task)))
    (roost--changing (roost--field task 'host) (roost--field task 'repo) files (roost--key task))))

(defun roost--changing (host repo files &optional except)
  "Tasks of the project REPO on HOST that change any of FILES, but EXCEPT.
REPO is the project's primary checkout there, EXCEPT a task's key.  A
list of (TASK . THOSE-FILES), in the order of `roost-tasks', from each
one's `roost--unmerged-files'."
  (let (found)
    (dolist (task (roost-tasks))
      (when-let* (((not (equal (roost--key task) except)))
                  ((equal (roost--field task 'host) host))
                  ((equal (roost--field task 'repo) repo))
                  (both (seq-filter (lambda (path) (member path files)) (roost--unmerged-files task))))
        (push (cons task both) found)))
    (nreverse found)))

(defun roost--conflict-next-step (task key)
  "What to do about TASK's conflicts with the branch it merges into.
KEY is a function that formats a key, as in `roost--next-step'."
  (if (memq (roost--pr-state (roost--pr-view task)) '(open draft))
      (roost--pr-next-step task key)
    (let ((integration (or (roost--field task 'integrationBranch) "its branch")))
      (format "Conflicts with %s in %s: %s merges %s into it, to resolve them there"
              integration (roost--file-list (roost--conflicts task))
              (funcall key "u") integration))))

(defun roost--pr-marker (task)
  "Compact pull request marker for TASK's dashboard row, such as \"#12 ✓\".
As `roost--pr-view' has it: the row says which branch the worktree is
on, and hovering, whose pull request this is."
  (if-let* ((task (roost--pr-view task))
            (pr (roost--field task 'pr))
            (state (roost--pr-state task)))
      (let* ((open (memq state '(open draft)))
             (counts (and open (roost--pr-checks task)))
             (review (and open (alist-get 'review (roost--field task 'prStatus))))
             (parts (delq nil
                          (list (propertize (roost--pr-number pr) 'face (roost--pr-face state))
                                (when counts
                                  (cond ((> (nth 1 counts) 0) (propertize "✗" 'face 'roost-status-failed))
                                        ((> (nth 2 counts) 0) (propertize "…" 'face 'roost-dim))
                                        (t (propertize "✓" 'face 'roost-dim))))
                                (pcase review
                                  ("APPROVED" (propertize "+" 'face 'roost-dim))
                                  ("CHANGES_REQUESTED" (propertize "!" 'face 'roost-status-permission)))
                                ;; Once merged, the commit counts no longer mean work to finish.
                                (unless open
                                  (propertize (symbol-name state) 'face (roost--pr-face state)))))))
        (if-let* ((branch (alist-get 'branch pr)))
            (propertize (string-join parts " ") 'help-echo (format "%s, the branch the worktree is on"
                                                                   (roost--pr-name task)))
          (string-join parts " ")))
    ""))

(defun roost--insert-issue (task)
  "Insert TASK's \"Issue\" section when it was started from an issue."
  (when-let* ((issue (roost--field task 'issue))
              ((or (alist-get 'number issue) (alist-get 'key issue))))
    (roost--insert-heading "Issue")
    (insert "  ")
    (if-let* ((url (alist-get 'url issue)))
        (insert-text-button (roost--issue-label issue)
                            'follow-link t 'face 'roost-field
                            'help-echo url
                            'action (lambda (_) (browse-url url)))
      (insert (propertize (roost--issue-label issue) 'face 'roost-field)))
    (insert (format "  %s\n" (or (alist-get 'title issue) "")))))

(defun roost--evidence-p (task)
  "Whether TASK's panel says what a merge of it would rest on.
That is while it has work to merge, or a pull request open."
  (let ((state (roost--pr-state (roost--pr-view task))))
    (or (and (memq state '(open draft)) t)
        (and (not (eq state 'merged))
             (not (roost--merged-p task))
             (or state (roost--field task 'files))
             t))))

(defconst roost--failed-checks-shown 5
  "How many failing checks a task panel names before counting the rest.")

(defun roost--insert-checks (task)
  "Insert, in TASK's panel, what the checks of its pull request say.
Each failing and pending check by name, as GitHub last said, and how
many passed.  Without a pull request, or with one that has no checks,
there are no CI results, which looks unlike checks that passed.  As
`roost--pr-view' has it."
  (let* ((task (roost--pr-view task))
         (state (roost--pr-state task))
         (status (roost--field task 'prStatus))
         (number (roost--pr-name task))
         (counts (roost--pr-checks task))
         (mark (lambda (mark face text) (concat (propertize mark 'face face) " " text))))
    (cond
     ;; With none to list, one quiet line, under no heading.
     ((not state) (roost--insert-quiet "No CI results: no pull request"))
     ((not status) (roost--insert-quiet (format "Not heard from %s about %s yet"
                                                (roost--forge-name (roost--field task 'pr)) number)))
     ((not counts) (roost--insert-quiet (format "No CI results on %s" number)))
     (t
      (roost--insert-heading "Checks")
      (pcase-let* ((`(,passing ,failing ,pending) counts)
                   (failed (seq-take (alist-get 'failingChecks status) (min failing roost--failed-checks-shown)))
                   (waiting (seq-take (alist-get 'pendingChecks status) (min pending 3)))
                   (unpushed (roost--field task 'unpushed))
                   (since (delq nil (list (cond ((and (numberp unpushed) (> unpushed 0))
                                                 (format "%d newer commit%s" unpushed (if (= unpushed 1) "" "s")))
                                                ;; Its head and the branch went apart, as
                                                ;; when a pushed commit was amended.
                                                ((and (assq 'unpushed task) (null unpushed))
                                                 "the branch as it is here"))
                                          (when (roost--field task 'dirty) "uncommitted changes")))))
        (dolist (name failed)
          (roost--insert-indented (funcall mark "✗" 'roost-status-failed (concat name " failed"))))
        (when (> failing (length failed))
          (roost--insert-indented (funcall mark "✗" 'roost-status-failed
                                           (format "%d %sfailed" (- failing (length failed))
                                                   (if failed "more " "")))))
        (when (> pending 0)
          (roost--insert-indented
           (funcall mark "…" 'roost-dim
                    (concat (format "%d pending" pending)
                            (when waiting
                              (concat ": " (string-join waiting ", ")
                                      (when (> pending (length waiting))
                                        (format " and %d more" (- pending (length waiting))))))))))
        (when (> passing 0)
          (roost--insert-indented (funcall mark "✓" 'roost-dim (format "%d passed" passing))))
        ;; Not of work since, which GitHub hasn't seen.
        (cond ((eq state 'closed)
               (roost--insert-indented (format "Run on %s, which is closed" number) 'roost-dim))
              (since
               (roost--insert-indented (format "Run on %s as pushed, not on %s" number (string-join since " or "))
                                       'roost-dim))))))))

(defconst roost--review-threads-shown 5
  "How many open review threads a task panel lists before counting the rest.")

(defun roost--insert-review-threads (task width)
  "Insert the unresolved review threads of TASK's open pull request.
Copilot's too, as GitHub last said, each with its file and line as a
button that visits them, and who started it with what, within WIDTH
columns.  As `roost--pr-view' has it."
  (when-let* ((task (roost--pr-view task))
              ((memq (roost--pr-state task) '(open draft)))
              (status (roost--field task 'prStatus))
              (count (alist-get 'threads status))
              ((natnump count))
              ((> count 0)))
    (roost--insert-heading "Open review threads")
    (let ((listed (seq-take (alist-get 'openThreads status) roost--review-threads-shown)))
      (dolist (thread listed)
        (roost--insert-review-thread task thread width))
      (when (> count (length listed))
        (roost--insert-indented
         (if listed
             (format "and %d more" (- count (length listed)))
           (format "%d on %s" count (roost--pr-name task)))
         'roost-dim)))))

(defun roost--insert-review-thread (task thread width)
  "Insert THREAD, one of TASK's open review threads, within WIDTH columns.
Its file and line are a button that visits them; the start of its
first comment follows, on a line of its own."
  (let* ((path (alist-get 'path thread))
         (line (alist-get 'line thread))
         (place (if line (format "%s:%d" path line) path))
         (author (alist-get 'author thread))
         (who (propertize (concat (if (stringp author) (roost--reviewer-name author) "someone")
                                  (when (alist-get 'outdated thread) " · outdated"))
                          'face 'roost-dim))
         (room (max 8 (- width 4 (string-width who))))
         (text (alist-get 'text thread))
         (visit (lambda () (roost--visit-review-thread task thread))))
    (insert "  ")
    ;; Long paths keep their end, which names the file.
    (insert-text-button (if (> (string-width place) room)
                            (concat "…" (truncate-string-to-width
                                         place (string-width place) (- (string-width place) (1- room))))
                          place)
                        'follow-link t 'face 'roost-field
                        'help-echo (concat place "\nmouse-1: "
                                           (if line "visit the line, as the pull request has it" "show its changes"))
                        'action (lambda (_)
                                  (roost--quit-questions-left-open visit)
                                  (funcall visit)))
    (insert "  " who "\n")
    (when (and (stringp text) (not (string-empty-p text)))
      (insert (propertize (concat (roost--truncate-width (roost--prose text) (max 12 (- width 4))) "\n")
                          'line-prefix "    " 'wrap-prefix "    ")))))

(defun roost--visit-review-thread (task thread)
  "Show where THREAD, one of TASK's open review threads, is.
On a line of its file as the pull request has it, that line in TASK's
worktree, in another window: the terminal or panel stays.  Commits or
changes since the pull request's head can have moved it.  Otherwise,
as on a deleted line, a line changed since or the whole file, the
file's changes, as its button in the file list shows them."
  (let ((path (alist-get 'path thread))
        (line (alist-get 'line thread)))
    (if (not line)
        (roost--diff-file task (or (seq-find (lambda (file) (equal (alist-get 'path file) path))
                                             (roost--field task 'files))
                                   (list (cons 'path path))))
      (roost--in-task-frame
       task (lambda ()
              (let ((default-directory (roost--remote-directory task)))
                (find-file-other-window (roost--worktree-file path))
                (goto-char (point-min))
                (forward-line (1- line))))))))

(defun roost--insert-pull-request (task)
  "Insert TASK's \"Pull request\" section when it has a pull request.
As `roost--pr-view' has it: the one from the branch its worktree is on
is headed so, and the task's own, if any, named below it."
  (when-let* ((view (roost--pr-view task))
              (pr (roost--field view 'pr))
              (state (roost--pr-state view)))
    (let* ((status (roost--field view 'prStatus))
           (review (alist-get 'review status))
           (reviewers (mapcar #'roost--reviewer-name (alist-get 'requested status)))
           (branch (alist-get 'branch pr))
           (own (alist-get 'number (roost--field task 'pr))))
      (roost--insert-heading "Pull request" (when branch (concat "from " branch)))
      ;; Both open it: the number, and the URL beside it, drawn as a link.
      (let* ((url (alist-get 'url pr))
             (open (lambda (label face)
                     (insert-text-button label 'follow-link t 'face face
                                         'help-echo (concat "Open " url)
                                         'action (lambda (_) (browse-url url))))))
        (insert "  ")
        (funcall open (roost--pr-number pr) 'roost-field)
        (when url
          (insert "  ")
          (funcall open url 'link))
        (insert "\n"))
      (roost--insert-indented
       (string-join
        (delq nil
              ;; Its checks and threads are under headings of their own.
              (list (propertize (pcase state ('draft "Draft") ('merged "Merged") ('closed "Closed")
                                  (_ "Open"))
                                'face (roost--pr-face state))
                    (when (and review (memq state '(open draft)))
                      (pcase review ("APPROVED" "approved") ("CHANGES_REQUESTED" "changes requested")
                        ("REVIEW_REQUIRED" "review required")))
                    (when (and (memq state '(open draft)) reviewers)
                      (concat "review requested from " (string-join reviewers ", ")))
                    (when (and (memq state '(open draft)) (equal (alist-get 'mergeable status) "CONFLICTING"))
                      "conflicts")))
        " · "))
      (when (eq state 'merged)
        (roost--insert-indented
         (cond ((not (if branch (roost--worktree-merged-p task) (roost--landed task)))
                (format "Merged on %s, but not the commits since." (roost--forge-name pr)))
               (branch
                (substitute-command-keys
                 (format "Merged on %s. \\<roost-task-info-mode-map>\\[roost-retire] discards this task, keeping %s."
                         (roost--forge-name pr) branch)))
               (t
                (substitute-command-keys
                 (format "Merged on %s. \\<roost-task-info-mode-map>\\[roost-retire] retires this task, removing its worktree and branch."
                         (roost--forge-name pr)))))
         'roost-dim))
      ;; Which the views follow again once the worktree is back on its branch.
      (when (and branch own)
        (roost--insert-indented (format "The task's branch %s has %s." (roost--field task 'branch)
                                        (roost--pr-number (roost--field task 'pr)))
                                'roost-dim)))))

;;;###autoload
(defun roost-copy-attach-command (&optional task)
  "Copy the shell command that attaches a terminal to TASK's agent.
Run it in another terminal, as a phone's SSH app or another machine,
to see and answer the agent in its real terminal, whichever agent it
is.  It attaches to the task's tmux session, over SSH for a task on
another host, and leaves Emacs's view of it as it is."
  (interactive)
  (setq task (roost--choose task))
  (unless (roost--field task 'live)
    (user-error "%s's agent isn't running, so there is no terminal to attach to; resume it first"
                (roost--field task 'name)))
  (let* ((host (roost--field task 'host))
         (attach (format "tmux -L %s attach -t %s"
                         (shell-quote-argument (or (roost--field task 'socket) "main"))
                         ;; By its whole name, not one that starts as it does.
                         (shell-quote-argument (concat "=" (roost--field task 'session)))))
         (command (if host
                      (format "ssh -t %s %s" (shell-quote-argument host) (shell-quote-argument attach))
                    attach)))
    (kill-new command)
    (message "Copied: %s" command)))

;;;###autoload
(defun roost-stop (&optional task)
  "Stop TASK's window, retaining its worktree, branch and conversation."
  (interactive)
  (setq task (roost--choose task))
  (when (y-or-n-p (format "Stop %s's window and its processes, keeping its work? "
                             (roost--field task 'name)))
    (roost--act task "stop")))

;;;###autoload
(defun roost-rename (&optional task name)
  "Rename TASK to NAME, in Roost and on its agent's tmux window.
Its branch and worktree keep the name it started with."
  (interactive)
  (setq task (roost--choose task))
  (let* ((old (roost--field task 'name))
         (name (string-trim (or name (read-string (format "Rename %s to: " old) old)))))
    (cond ((not (string-match-p "[[:alnum:]]" name))
           (user-error "Give the task a name containing letters or numbers"))
          ((equal name old) (message "%s keeps its name" old))
          (t (roost--act task "rename" `((name . ,name))
                         ;; Caching the reply renames its workspace and panel.
                         (lambda (_) (message "Renamed %s to %s" old name)))))))

;;;###autoload
(defun roost-retarget (&optional task base)
  "Change the branch TASK starts from and merges into to BASE.
As when it started from the wrong branch and you have since rebased its
own onto the right one: `m' then merges it there, `u' merges that
branch into it, and its commits and changes count from it.  A
remote-tracking branch, such as origin/main, gives the local branch of
its name, as for a new task.  No commit moves, and a pull request
already open keeps its base, which Roost says."
  (interactive)
  (setq task (roost--choose task))
  (roost--refuse-conversation task "has no branch to merge into")
  (let* ((name (roost--field task 'name))
         (now (roost--field task 'integrationBranch))
         (base (string-trim
                (or base
                    (completing-read
                     (format "%s merges into %s; change to: " name
                             (if (member now '(nil "")) "no branch" now))
                     ;; Git runs on the task's host.  Not its own branch,
                     ;; which merges into no other.
                     (remove (roost--field task 'branch)
                             (when (roost--field task 'repo)
                               (split-string (or (roost--git-in (roost--project-directory task) "for-each-ref"
                                                                "--format=%(refname:short)"
                                                                "refs/heads" "refs/remotes")
                                                 "")
                                             "\n" t))))))))
    (when (string-empty-p base)
      (user-error "Name the branch %s should merge into" name))
    (roost--act task "retarget" `((base . ,base))
                (lambda (updated)
                  (message "%s now merges into %s%s" name (roost--field updated 'integrationBranch)
                           (if-let* ((note (roost--field updated 'note))) (concat "; " note) ""))
                  ;; What it is ahead and behind by, and conflicts with, as
                  ;; measured against the new branch.
                  (roost--refresh-host (roost--field updated 'host) nil (list (roost--field updated 'id)))))))

(defun roost--landed (task &optional measured)
  "Whether TASK's commits are all merged, as its host last measured.
That is, in its integration branch or a pull request GitHub merged at
its tip.  Its host saying they aren't settles it.  That they are counts
once its Git statistics are measured too: until then, as after a poll
that only asked GitHub, the merge on GitHub is all there is to go on,
and with MEASURED the answer is `unknown'."
  (cond ((and (assq 'landed task) (not (roost--field task 'landed))) nil)
        ((and (assq 'landed task) (assq 'dirty task)) t)
        (measured 'unknown)
        (t (eq (roost--pr-state task) 'merged))))

(defun roost--other-branch (task)
  "The branch TASK's worktree is on when it isn't the task's, or nil.
\"HEAD\" for a detached HEAD.  As after you or its agent made a branch
there: its Git statistics are then that branch's, while its host
refuses to merge, push, update or retire the task, which act on the
task's branch.  Nil too from a helper too old to say."
  (let ((branch (roost--field task 'worktreeBranch)))
    (and (stringp branch) (not (string-empty-p branch)) branch)))

(defun roost--branch-label (branch)
  "BRANCH, from `roost--other-branch', as words."
  (if (equal branch "HEAD") "a detached HEAD" branch))

(defun roost--other-branch-ways (task key)
  "How to finish TASK, whose worktree is on another branch, naming keys with KEY.
KEY is a function that formats a key, as in `roost--next-step'.
Discarding keeps that branch, and merging needs the task's back, unless
a pull request from there merged it all."
  (let ((branch (roost--other-branch task))
        (own (roost--field task 'branch))
        (ahead (roost--field task 'ahead)))
    (concat (funcall key "x") " discards the task"
            (unless (equal branch "HEAD") (format ", keeping %s" branch))
            (when (and (numberp ahead) (> ahead 0) (roost--action-applies-p task 'roost-merge-retire)
                       (not (roost--worktree-merged-p task)))
              (concat "; to merge its work with " (funcall key "m") " or " (funcall key "P") ", "
                      (if (equal branch "HEAD")
                          (format "bring its commits onto %s and check that out there" own)
                        (format "check out %s there and merge %s into it" own branch)))))))

(defun roost--other-branch-step (task key)
  "What to do next with TASK, whose worktree is on another branch.
KEY is a function that formats a key, as in `roost--next-step'.  Its
host won't merge or retire it there."
  (concat (if (roost--worktree-merged-p task)
              (format "%s is merged: " (roost--pr-name task))
            (format "Its worktree is on %s, not the task's branch: "
                    (roost--branch-label (roost--other-branch task))))
          (roost--other-branch-ways task key)))

(defun roost--unmerged-work-p (task)
  "Whether TASK, as last seen, holds work that retiring it would refuse to lose.
Commits not merged into its integration branch, or files not committed."
  (or (roost--field task 'dirty)
      (and (numberp (roost--field task 'ahead)) (> (roost--field task 'ahead) 0)
           ;; Commits since a pull request merged are not in it.
           (not (roost--landed task)))))

;;;###autoload
(defun roost-retire (&optional task)
  "Finish with TASK: remove its worktree, branch and window.
When its work is merged, or it has none, retire it.  When it holds work
nothing else has, offer to discard it, saying what that loses: `m'
merges its commits instead, and for work not yet committed, `r' opens
Magit to commit it.  With its worktree on another branch, which its host
won't retire, offer to discard it, which keeps that branch."
  (interactive)
  (setq task (roost--choose task))
  (let* ((name (roost--field task 'name))
         (key (roost--key task))
         (listed (gethash key roost--tasks))
         (offer (lambda (&optional branch)
                  (when (y-or-n-p
                         (if branch
                             ;; Discarding keeps the branch; m won't merge it.
                             (format "%s's worktree is on %s, not its branch %s%s.  Discard the task%s? "
                                     name (roost--branch-label branch) (roost--field task 'branch)
                                     (if (roost--field task 'dirty)
                                         (substitute-command-keys
                                          ", with changes not committed (\\<roost-task-info-mode-map>\\[roost-review] commits them in Magit)")
                                       "")
                                     (if (equal branch "HEAD") "" (format ", keeping %s" branch)))
                           (substitute-command-keys
                            (format "%s has work not merged into %s (%s).  Discard it? "
                                    name (or (roost--field task 'integrationBranch) "its branch")
                                    ;; m merges only committed work.
                                    (if (roost--field task 'dirty)
                                        "\\<roost-task-info-mode-map>\\[roost-review] commits it in Magit"
                                      "\\<roost-task-info-mode-map>\\[roost-merge-retire] merges it")))))
                    (roost-discard task))))
         (retire (lambda ()
                   (roost--act task "retire" nil
                               (lambda (retired)
                                 (roost--retired-workspace retired)
                                 (roost--kill-worktree-buffers retired)
                                 (message "Retired %s, and removed its worktree and branch" name))
                               (lambda (err)
                                 ;; Git statistics newer than Roost's.
                                 (cond
                                  ((string-match-p "\\`\\(Task branch has unmerged\\|Uncommitted or untracked\\)" err)
                                   (roost--ask-after-reply key listed offer))
                                  ((string-match "\\`The task's worktree is on \\(.+?\\), not the task's branch" err)
                                   (let ((branch (match-string 1 err)))
                                     (roost--ask-after-reply
                                      key listed
                                      (lambda ()
                                        (funcall offer (if (equal branch "a detached HEAD") "HEAD" branch))))))
                                  (t (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err))))))))
    (cond
     ((member (roost--field task 'status) '("starting" "running" "permission" "background"))
      (user-error "%s's agent is at work; stop it (K) first, or wait" name))
     ((roost--other-branch task)
      (funcall offer (roost--other-branch task)))
     ((roost--unmerged-work-p task)
      (funcall offer))
     ((y-or-n-p (concat (roost--offers-sentence task)
                        (format "Retire %s, removing its worktree and branch (nothing in them would be lost)? "
                                name)))
      (funcall retire)))))

;;;###autoload
(defun roost-merge-retire (&optional task)
  "Merge TASK's committed work into its recorded integration branch and retire.
Dirty worktrees are refused; review and commit in Magit first.  The work
comes in as one squashed commit, or a merge commit; see `roost-merge-style'.
A branch that moved while you were asked isn't merged: you look again."
  (interactive)
  (setq task (roost--choose task))
  (roost--refuse-conversation task "has no project to merge into")
  (cond
   ;; Nor will it merge from a worktree on another branch.
   ((roost--other-branch task)
    (user-error "%s's worktree is on %s, not its branch %s; check out %s there, with the commits to merge, first"
                (roost--field task 'name) (roost--branch-label (roost--other-branch task))
                (roost--field task 'branch) (roost--field task 'branch)))
   ;; The host refuses a dirty worktree; say so rather than ask to merge.
   ((roost--field task 'dirty)
    (when (y-or-n-p (format "%s has uncommitted changes to commit first.  Open Magit? "
                            (roost--field task 'name)))
      (roost-review task)))
   ((y-or-n-p (concat (roost--since-looked-sentence task)
                      (roost--offers-sentence task)
                      (format (if (eq roost-merge-style 'squash)
                                  "Squash committed work from %s into one commit on %s and retire it? "
                                "Merge committed work from %s into %s and retire it? ")
                              (roost--field task 'name)
                              (or (roost--field task 'integrationBranch) "its branch"))))
    (roost--act task "merge" (append (when (eq roost-merge-style 'squash) '((style . "squash")))
                                     ;; Where the branch was as you were asked: an
                                     ;; agent can commit before you answer.
                                     (when-let* ((tip (roost--field task 'branchTip)))
                                       (list (cons 'expect tip))))
                (lambda (merged)
                  (roost--retired-workspace merged)
                  (roost--kill-worktree-buffers merged)
                  (roost--revert-merged-files merged)
                  (roost--report-merge merged (roost--field merged 'retiringCommit)
                                       (or (roost--field merged 'integrationBranch)
                                           (roost--field task 'integrationBranch)))
                  ;; The other tasks are measured against the branch that moved.
                  (roost--refresh-host (roost--field merged 'host) nil)
                  (message (concat (if (eq roost-merge-style 'squash)
                                       "Squashed %s into %s, and removed its worktree and branch"
                                     "Merged %s into %s, and removed its worktree and branch")
                                   "%s")
                           (roost--field task 'name)
                           (or (roost--field task 'integrationBranch) "its branch")
                           ;; The other attempts at its prompt stay until you finish them.
                           (if-let* ((others (roost--attempts task)))
                               (format "; %s %s"
                                       (roost--names (mapcar (lambda (other) (roost--field other 'name)) others))
                                       (if (cdr others) "remain: x on each discards it" "remains: x discards it"))
                             "")))
                (lambda (err)
                  (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err)
                  ;; So that `m' asks about where it is now, watching or not.
                  (when (string-prefix-p "The task's branch has moved" err)
                    (roost--refresh-host (roost--field task 'host) nil (list (roost--field task 'id)))))))))

;;;###autoload
(defun roost-forget (&optional task)
  "Drop TASK from Roost, leaving its worktree and branch as they are.
The way out for a task Roost can no longer retire, such as one whose
repository moved; `roost-retire' finishes a task, or discards it.  A
running agent is stopped first."
  (interactive)
  (setq task (roost--choose task))
  (let* ((name (roost--field task 'name))
         ;; The host refuses while the agent runs, so stop it first.
         (running (roost--agent-running-p task))
         (forget (lambda (&rest _)
                   (roost--act task "forget" nil
                               (lambda (forgotten)
                                 (roost--retired-workspace forgotten)
                                 (when-let* ((left (roost--field forgotten 'leftBehind)))
                                   (message "Forgot %s; left in place: %s"
                                            name (string-join left ", "))))))))
    (when (yes-or-no-p (concat (roost--offers-sentence task)
                               (format (if running
                                           "Stop %s's agent and forget the task, leaving its worktree and branch as they are? "
                                         "Forget %s, leaving its worktree and branch as they are? ")
                                       name)))
      (if running
          (roost--act task "stop" nil forget)
        (funcall forget)))))

;;;###autoload
(defun roost-discard (&optional task)
  "Delete TASK's worktree, branch and window, and drop it from Roost.
First says what would be lost, commits no other branch holds, commits in
submodules no remote has and files not committed, here and in worktrees
its agent made, which go too; to
lose any, you type the task's name.  A task that holds more by the time
you answer isn't discarded, and asking again says what.  For an
experiment you don't want; finished work is merged or retired instead."
  (interactive)
  (setq task (roost--choose task))
  (let* ((name (roost--field task 'name))
         (listed (gethash (roost--key task) roost--tasks))
         (told (alist-get 'discard
                          (roost--request-wait (roost--field task 'host) "discard"
                                               (list (cons 'id (roost--field task 'id))
                                                     (cons 'dryRun t)))))
         ;; While its host replied.
         (_ (when (roost--went-p (roost--key task) listed)
              (user-error "%s is no longer listed" name)))
         (commits (or (alist-get 'commits told) 0))
         (submodule-commits (or (alist-get 'submoduleCommits told) 0))
         (unread (or (alist-get 'unreadSubmodules told) 0))
         (changes (or (alist-get 'changes told) 0))
         (worktrees (or (alist-get 'agentWorktrees told) 0))
         (losses (delq nil (list (when (> commits 0)
                                   (format "%d commit%s no other branch has"
                                           commits (if (= commits 1) "" "s")))
                                 (when (> submodule-commits 0)
                                   (format "%d commit%s in its submodules that no remote has"
                                           submodule-commits (if (= submodule-commits 1) "" "s")))
                                 (when (> unread 0)
                                   (format "whatever is in %d submodule repositor%s Git can't read"
                                           unread (if (= unread 1) "y" "ies")))
                                 (when (> changes 0)
                                   (format "%d uncommitted file%s"
                                           changes (if (= changes 1) "" "s"))))))
         (label (if (> worktrees 0)
                    (format "%s, with %d worktree%s its agent made,"
                            name worktrees (if (= worktrees 1) "" "s"))
                  name)))
    (if (not (if losses
                 (equal (string-trim
                         (read-string (format "%sDiscarding %s loses %s%s.  Type its name to discard it: "
                                              (roost--offers-sentence task)
                                              label (if (cdr losses)
                                                        (concat (string-join (butlast losses) ", ")
                                                                " and " (car (last losses)))
                                                      (car losses))
                                              (if (roost--agent-running-p task) ", and stops its agent" ""))))
                        name)
               (y-or-n-p (concat (roost--offers-sentence task)
                                 (format "Discard %s, %sdeleting its worktree and branch (nothing in them would be lost)? "
                                         label (if (roost--agent-running-p task) "stopping its agent and " ""))))))
        (message "%s was not discarded" name)
      (roost--act task "discard" (list (cons 'expect (alist-get 'commit told))
                                       ;; Its host counts again, as its agent may
                                       ;; have gone on working while you read.
                                       (cons 'told (assq-delete-all 'commit (copy-alist told))))
                  (lambda (discarded)
                    (roost--retired-workspace discarded)
                    (roost--kill-worktree-buffers discarded)
                    (message "Discarded %s" name))))))

(defun roost--kill-worktree-buffers (task)
  "Kill the Magit and Dired buffers left in TASK's removed worktree.
A window made to show one goes away, as the panel's does, rather than
show some other buffer beside the one the terminal's window went back
to.  File buffers stay, since they may hold unsaved edits."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (and (derived-mode-p 'magit-mode 'dired-mode)
                      (roost--task-in-directory default-directory (list task)))))
      (roost--close-buffer buffer))))

(defun roost--revert-merged-files (task)
  "Revert the buffers of files a merge of TASK changed in its primary checkout.
Only those with no unsaved edits, and only here: on another host it
would cost a round trip for each.  Revert mode would do it a moment
later, saying so over what the merge said."
  (when-let* (((null (roost--field task 'host)))
              (repo (roost--field task 'repo))
              ;; By true names: one of you may reach it through a link.
              (directory (file-name-as-directory (file-truename repo))))
    (dolist (buffer (buffer-list))
      (when-let* ((file (buffer-file-name buffer))
                  (true (buffer-local-value 'buffer-file-truename buffer)))
        (when (and (string-prefix-p directory (expand-file-name true))
                   (not (buffer-modified-p buffer))
                   (file-exists-p file)
                   (not (verify-visited-file-modtime buffer)))
          (with-current-buffer buffer
            (ignore-errors (revert-buffer t t t))))))))

(defun roost--retired-workspace (task)
  "Remove TASK's workspace and panel, retaining other buffers.
A window made to show the panel goes away; any other goes back to what
it showed before.  In every frame, and you stay in yours: quitting a
window in another frame, or closing its current tab or perspective,
which restores a window configuration of that frame, selects it."
  (let ((key (roost--key task))
        (selected (selected-frame)))
    (dolist (buffer (buffer-list))
      (when (and (equal (buffer-local-value 'roost--buffer-task-key buffer) key)
                 (eq (buffer-local-value 'major-mode buffer) 'roost-task-info-mode))
        (roost--close-buffer buffer)))
    ;; Each frame has tabs of its own, or perspectives, which may have
    ;; any name the task had.
    (dolist (frame (frame-list))
      (unless (frame-parent frame)
        (with-selected-frame frame
          (pcase (roost--workspace-backend)
            ('perspective
             (when (fboundp 'persp-kill)
               (roost--kill-perspective (roost--perspective-name task))))
            ('tab-bar
             (let ((name (roost--task-tab task)))
               (when (and name (cdr (roost--tabs)))
                 (tab-bar-close-tab-by-name name))))))))
    (remhash key roost--perspectives)
    (unless (or (eq (selected-frame) selected) (not (frame-live-p selected)))
      (select-frame selected))))

(defun roost--kill-perspective (name)
  "Kill the selected frame's perspective NAME, but not its buffers.
`persp-kill' kills each buffer no other perspective has, files you
opened in a task's workspace among them.  Those stay, in no perspective,
as `persp-forget-buffer' leaves one.  The perspective's own scratch
buffer goes while it holds only what it began with."
  (when (member name (persp-names))
    (let* ((scratch (get-buffer (persp-scratch-buffer name)))
           (may-kill (lambda ()
                       (and (eq (current-buffer) scratch) (not (buffer-modified-p))))))
      ;; Bound where no buffer-local value hides the global one, which
      ;; is what the buffers being killed run.
      (with-temp-buffer
        (let ((kill-buffer-query-functions (cons may-kill kill-buffer-query-functions)))
          (persp-kill name))))))

;;;###autoload
(defun roost-next-waiting ()
  "Open the next task whose agent is waiting for you.
Permission requests and agents stuck at a startup prompt come first,
since they block their agent; then tasks ready for a prompt, those that
failed, crashed or exited, and those whose pull request waits on you,
in turn.  The echo area says which task it opened, why that one
waits, and how many more do.

Once none does, it offers to go back to where you were when you pressed
the first of a run: the next press goes there.  With workspaces, that is
the workspace you were in; without, the frame's windows as they were."
  (interactive)
  (let* ((waiting (sort (seq-filter #'roost--waiting-p (roost-tasks))
                        (lambda (a b) (< (roost--attention-rank a) (roost--attention-rank b)))))
         (keys (mapcar #'roost--key waiting))
         ;; The task you are looking at, which is never the dashboard's row:
         ;; a blocked task you just created or left must still come first.
         (viewing (unless (derived-mode-p 'roost-dashboard-mode)
                    (when-let* ((task (ignore-errors (roost--task-at-point))))
                      (roost--key task))))
         (blocked (mapcar #'roost--key (seq-filter #'roost--blocked-p waiting)))
         (others (seq-difference keys blocked))
         (key (if (and blocked (not (equal blocked (list viewing))))
                  ;; In turn from the one you are looking at, if blocked.
                  (or (cadr (member viewing blocked))
                      (seq-find (lambda (key) (not (equal key viewing))) blocked))
                ;; Back from a blocked task, on from the last other one.
                (or (cadr (member (if (member viewing blocked)
                                      roost--next-unblocked
                                    (or viewing roost--current-task))
                                  others))
                    (car others) (car keys))))
         ;; Pressed in a task it opened, a run goes on.
         (run (when-let* ((here (roost--task-here)))
                (and (member (roost--key here) (plist-get roost--next-run :opened))
                     roost--next-run))))
    (cond
     (key
      (cond ((member key others) (setq roost--next-unblocked key))
            ((member viewing others) (setq roost--next-unblocked viewing)))
      (setq roost--next-run (plist-put (plist-put (copy-sequence (or run (roost--place-here))) :offered nil)
                                       :opened (cons key (plist-get run :opened))))
      (roost-open-task (gethash key roost--tasks) t #'roost--next-message))
     ((not run)
      (setq roost--next-run nil)
      (user-error "No tasks are waiting for you"))
     ((plist-get run :offered)
      (setq roost--next-run nil)
      ;; Quitting a question left open gives back the windows it found,
      ;; which would undo the way back: so first.
      (roost--quit-questions-left-open (lambda () (roost--go-back run)))
      (roost--go-back run))
     (t
      (setq roost--next-run (plist-put run :offered t))
      (message "No tasks are waiting for you; %s again goes back to %s"
               (propertize "n" 'face 'roost-key) (roost--place-name run))))))

(defun roost--task-here ()
  "The task where you are, for `roost-next-waiting', or nil.
From the sidebar or a docked panel, that of the main window you were in
last; from the dashboard, the frame's, as `roost--frame-task' has it."
  (with-current-buffer (if (window-parameter nil 'window-side)
                           (window-buffer (roost--selected-main-window))
                         (current-buffer))
    (if (derived-mode-p 'roost-dashboard-mode)
        (roost--frame-task)
      (ignore-errors (roost--task-at-point)))))

(defun roost--place-here ()
  "Where you are, for `roost-next-waiting' to go back to: see `roost--next-run'."
  (list :frame (selected-frame)
        :workspace (roost--current-workspace)
        :owner (when-let* (((roost--workspace-backend))
                           (task (roost--frame-task))
                           ((equal (roost--workspace-name task) (roost--current-workspace))))
                 (roost--key task))
        :windows (current-window-configuration)
        :task (frame-parameter nil 'roost-task)
        :current roost--current-task
        :buffer (window-buffer (roost--selected-main-window))))

(defun roost--place-name (run)
  "What to call where RUN of `roost-next-waiting' began, from its buffer."
  (let ((buffer (plist-get run :buffer)))
    (cond ((not (buffer-live-p buffer)) "where you were")
          ((with-current-buffer buffer (derived-mode-p 'roost-dashboard-mode)) "the dashboard")
          ((when-let* ((task (roost--terminal-task buffer)))
             (roost--field task 'name)))
          (t (buffer-name buffer)))))

(defun roost--go-back (run)
  "Go back to where you were when RUN of `roost-next-waiting' began.
With workspaces, to the workspace you were in, as you left it; without,
or in that workspace still, to the frame's windows as they were then."
  (let ((frame (plist-get run :frame))
        (name (roost--place-name run))
        workspace)
    (unless (frame-live-p frame)
      (user-error "The frame you were in is gone"))
    ;; A task still opening, on a host slow to reply, stays where it is.
    (cl-incf roost--open-generation)
    (unless (eq frame (selected-frame))
      (select-frame-set-input-focus frame))
    ;; A task's, by the name it has now: it may have been renamed since.
    (setq workspace (if-let* ((owner (gethash (plist-get run :owner) roost--tasks)))
                        (roost--workspace-name owner)
                      (plist-get run :workspace)))
    (pcase (and workspace (not (equal workspace (roost--current-workspace))) (roost--workspace-backend))
      ('perspective
       (unless (member workspace (persp-names))
         (user-error "The workspace you were in, %s, is gone" workspace))
       (persp-switch workspace))
      ('tab-bar
       (unless (member workspace (roost--tabs))
         (user-error "The tab you were in, %s, is gone" workspace))
       (tab-bar-select-tab-by-name workspace))
      (_
       (set-window-configuration (plist-get run :windows))
       ;; The panel and the sidebar's mark follow the frame's task.
       (set-frame-parameter nil 'roost-task (plist-get run :task))
       (setq roost--current-task (plist-get run :current))))
    (roost--mark-in-sidebar)
    (message "Back to %s" name)))

(defun roost--waiting-reason (task)
  "Why TASK waits for you, on one line, or nil.
As its notification says: what its agent asks, the first line of its
latest reply, why its pull request waits on you, or how it failed; or
what it conflicts with."
  (let* ((status (roost--attention-status task))
         (why (cond ((equal status "permission") (roost--permission-request task))
                    ((equal status "prompt") "It may be waiting at a startup prompt, such as folder trust")
                    ((member status (cons "conflicts" roost--pr-turns)) (roost--turn-reason task status))
                    ((member status '("error" "failed" "crashed" "exited"))
                     (roost--field task 'error))
                    (t (roost--last-message-summary task)))))
    (when (stringp why)
      (let ((line (roost--one-line why)))
        (unless (string-empty-p line) line)))))

(defun roost--next-message (task)
  "What `roost-next-waiting' says once it opens TASK, as it was before.
Its status and name, why it waits, and how many other tasks wait, on
one line of the echo area.  Why it waits is cut short to fit, then the
rest from its end: its status and name come first, and are read first."
  (let* ((key (roost--key task))
         (more (seq-count (lambda (other) (and (not (equal (roost--key other) key)) (roost--waiting-p other)))
                          (roost-tasks)))
         (head (concat (propertize (roost--display-status task)
                                   'face (roost--status-face (roost--attention-status task)))
                       " · " (roost--field task 'name)))
         (why (roost--waiting-reason task))
         (tail (concat (when (roost--action-applies-p task #'roost-resume)
                         (concat "; " (propertize "s" 'face 'roost-key) " resumes it"))
                       (if (> more 0) (format "; %d more waiting" more) "; no more waiting")))
         (width (window-max-chars-per-line (minibuffer-window))))
    ;; Measured as the echo area shows it, in no buffer's faces.
    (with-temp-buffer
      (let ((room (- width (roost--text-width head) (roost--text-width tail) 2)))
        (roost--truncate-width
         (concat head
                 (when (and why (>= room 8))
                   (concat ": " (roost--truncate-width why room)))
                 tail)
         width)))))

(defun roost--project-name (task)
  "Short primary repository name for TASK."
  (if (roost--conversation-p task)
      "Conversations"
    (file-name-nondirectory (directory-file-name (or (roost--field task 'repo) "unknown")))))

;;;; Since you last looked

(defun roost--since-looked (task)
  "What changed in TASK since you last looked at it, as (COUNT . AT), or nil.
You look at a task when you open it in Magit with `roost-review', send
its agent your notes, or say so with `roost-mark-looked'.  COUNT is how
many files changed since then, by content: uncommitted work counts, and
commits remade of what you saw, as by an amend or a rebase, don't.  AT
is when you looked, or nil if you never have, and then COUNT is how
many files the task changes.  Nil until its host has measured it since
you looked, and without Magit for a task you never looked at."
  (let ((looked (roost--field task 'looked))
        (since (roost--field task 'sinceLooked)))
    (cond (looked
           ;; Measured since this look, not the one before it.
           (when (equal (alist-get 'at since) (alist-get 'at looked))
             (cons (or (alist-get 'count since) 0) (alist-get 'at looked))))
          ;; Without Magit, where `roost-review' opens Dired and records
          ;; no look, it doesn't say so.
          ((and (fboundp 'magit-status) (assq 'diff task))
           (let ((diff (or (roost--field task 'diff) "")))
             (cons (or (alist-get 'files (roost--field task 'size))
                       ;; From a helper that doesn't measure the size.
                       (+ (if (string-match "\\([0-9]+\\) files? changed" diff)
                              (string-to-number (match-string 1 diff))
                            0)
                          (seq-count (lambda (file) (alist-get 'untracked file)) (roost--field task 'files))))
                   nil))))))

(defun roost--since-looked-text (task &optional short)
  "What changed in TASK since you last looked at it, in a few words, or nil.
SHORT leaves out since when.  Nil when nothing did."
  (pcase (roost--since-looked task)
    (`(,count . ,at)
     (when (> count 0)
       (let ((files (format "%d file%s" count (if (= count 1) "" "s"))))
         (cond ((and short at) (concat files " changed"))
               (short "not looked at")
               (at (concat files " changed since you looked"))
               (t (concat files " not looked at"))))))))

(defun roost--since-looked-due-p (task)
  "Whether to say what changed in TASK since you last looked at it.
Not while its agent works or asks, which changes more, and not for work
that is merged."
  (not (or (member (roost--status-name task) '("starting" "running" "background" "permission"))
           (member (roost--display-status task) '("merged" "offline")))))

(defun roost--since-looked-shown-p (task)
  "Whether TASK's row says what changed since you last looked at it.
Once you have seen its agent, as `roost--since-looked-due-p' has it.
It is no reason to wait for you."
  (and (roost--seen-p task) (roost--since-looked-due-p task)))

(defun roost--with-since-looked (task text)
  "TEXT about TASK, after what changed since you last looked, if a row says so."
  (if-let* (((roost--since-looked-shown-p task))
            (since (roost--since-looked-text task)))
      (if text (concat since " · " text) since)
    text))

(defun roost--since-looked-sentence (task)
  "What changed in TASK since you last looked, as a sentence to ask after, or \"\"."
  (if-let* ((text (roost--since-looked-text task)))
      (concat (capitalize (substring text 0 1)) (substring text 1) ".  ")
    ""))

(defun roost--insert-other-branch (task &optional next)
  "Insert, in TASK's panel, the branch its worktree is on when not the task's.
Its changes are that branch's.  How to finish the task follows, unless
NEXT, the panel's next step, says it already, or `x' won't retire it, as
while its agent is at work.  When NEXT says it, it has said which branch
the worktree is on, so this says only whose the changes are, naming the
task's branch, which you would check out to merge them; in the same
colour, which reminds you the worktree is not on it."
  (when-let* ((branch (roost--other-branch task))
              ((not (roost--field task 'worktreeMissing))))
    (let ((own (roost--field task 'branch))
          (changes (not (string-empty-p (roost--changes task)))))
      (roost--insert-loud
       (concat (format "On %s, not the task's branch %s" (roost--branch-label branch) own)
               (when changes
                 (if (equal branch "HEAD") ", so the changes below are those there"
                   (format ", so the changes below are %s's" branch)))
               (unless (or (roost--names-key-p next "x") (not (roost--action-applies-p task 'roost-retire)))
                 (concat ": " (roost--other-branch-ways task (lambda (key) (propertize key 'face 'roost-key)))))
               ".")
       'roost-status-permission))))

(defun roost--insert-since-looked (task &optional next)
  "Insert, in TASK's panel, what changed since you last looked at it.
It names the keys of `roost-review', to see what changed, and
`roost-mark-looked', to say you have looked without opening Magit,
unless NEXT, the panel's next step, names them already.  The task panel
says a key once."
  (let* ((key (lambda (command)
                (let ((key (substitute-command-keys
                            (format "\\<roost-task-info-mode-map>\\[%s]" command))))
                  (when (and (roost--action-applies-p task command)
                             (not (roost--names-key-p next key)))
                    (propertize key 'face 'roost-key)))))
         ;; Without Magit, it opens Dired.
         (review (and (fboundp 'magit-status) (funcall key 'roost-review)))
         (mark (funcall key 'roost-mark-looked))
         (keys (lambda (shows)
                 (when-let* ((said (delq nil (list (and review (concat review " " shows))
                                                   (and mark (concat mark " marks it looked at"))))))
                   (concat ": " (string-join said ", "))))))
    (pcase (and (roost--since-looked-due-p task) (roost--since-looked task))
      (`(,count . ,at)
       (cond ((not at)
              (when (> count 0)
                (roost--insert-indented (concat "Not looked at yet" (funcall keys "opens it in Magit"))
                                        'roost-dim)))
             ((= count 0)
              ;; Only once its agent has done something since: right after
              ;; a look, it would say nothing you don't know.
              (when-let* ((moved (roost--time (roost--field task 'updatedAt)))
                          (looked (roost--time at))
                          ((time-less-p looked moved)))
                (roost--insert-indented (format "Nothing changed since you looked, %s ago" (roost--elapsed at))
                                        'roost-dim)))
             (t
              (roost--insert-indented
               (concat (format "%d file%s changed since you looked, %s ago"
                               count (if (= count 1) "" "s") (roost--elapsed at))
                       (funcall keys "shows them"))
               'roost-dim)))))))

(defun roost--names-key-p (text key)
  "Whether TEXT, as a next step, tells you to press KEY.
The task panel says a key once: a line that would name it again leaves
it to the next step."
  (and text
       (let ((start 0) found)
         (while (and (not found) (< start (length text)))
           (let ((end (or (next-single-property-change start 'face text) (length text))))
             (setq found (and (memq 'roost-key (ensure-list (get-text-property start 'face text)))
                              (equal (substring-no-properties text start end) key))
                   start end)))
         found)))

;;;; Shared display helpers

(defun roost--status-name (task)
  "TASK's status as Roost names it.
That is its recorded status, except \"error\" for a turn that failed,
as on a usage limit, while the agent waits: one that died has failed.
A turn you interrupted, or whose permission prompt you declined, is
\"interrupted\" rather than \"ready\": its agent stopped mid-way."
  (let ((status (roost--field task 'status)))
    (cond ((and (equal status "failed") (roost--field task 'live)) "error")
          ((and (equal status "ready") (equal (roost--field task 'lastEvent) "Interrupt"))
           "interrupted")
          (t status))))

(defun roost--display-status (task)
  "TASK's status, or \"offline\" while its host is unreachable.
It is \"merged\" when you can retire it, losing nothing, and its agent
neither works nor has anything new for you, one of `roost--pr-turns'
while its pull request waits on you, and \"conflicts\" as
`roost--conflict-turn' has it."
  (cond ((gethash (roost--field task 'host) roost--errors) "offline")
        ((roost--merged-p task) "merged")
        ((roost--pr-turn task))
        ((roost--conflict-turn task) "conflicts")
        (t (roost--status-name task))))

(defun roost--merged-p (task)
  "Whether TASK's work is merged, as its host last measured, and nothing needs you.
Its commits are in its integration branch or a pull request GitHub
merged, nothing is left uncommitted, its worktree is on its branch, and
its agent is not at work, did not fail, and has said nothing you haven't
seen."
  (and (eq (roost--landed task t) t)
       (not (roost--field task 'dirty))
       (not (roost--field task 'merging))
       (not (roost--field task 'worktreeMissing))
       (not (roost--other-branch task))
       (not (roost--agent-work-left task))
       (not (member (roost--field task 'status)
                    '("starting" "running" "permission" "background" "failed" "crashed")))
       ;; Stopped too: its host keeps it seen only if it was before.
       (roost--seen-p task)))

(defun roost--status-face (status)
  "Face for STATUS."
  (pcase status
    ((or "permission" "prompt" "comments" "conflicts") 'roost-status-permission)
    ((or "ready" "interrupted" "to merge") 'roost-status-ready)
    ((or "running" "background") 'roost-status-running)
    ((or "failed" "crashed" "error" "ci failed") 'roost-status-failed)
    (_ 'roost-status-inactive)))

(defun roost--status-word-face (status)
  "Face for STATUS, from `roost--attention-status', written beside its dot.
The dot has the status's colour.  The word has it too when the agent
can't go on without you or failed, is plain while the agent waits for
you otherwise, or the task is merged (`roost-pr-merged'), and is dim the
rest of the time."
  (pcase status
    ((or "permission" "prompt" "error" "failed" "crashed" "ci failed") (roost--status-face status))
    ("merged" 'roost-pr-merged)
    ((or "ready" "interrupted" "to merge" "comments" "conflicts") nil)
    (_ 'roost-dim)))

(defvar roost--mark-glyphs nil
  "The disc and dotted circle of `roost--status-mark', as (DISC . CIRCLE).
Bound while a view draws its rows, so the display is asked once.")

(defun roost--mark-glyphs ()
  "The disc and dotted circle of `roost--status-mark', as (DISC . CIRCLE).
Plain characters where the display can't draw them."
  (or roost--mark-glyphs
      (cons (if (char-displayable-p ?●) "●" "*")
            (if (char-displayable-p ?◌) "◌" "~"))))

(defun roost--status-mark (status waiting)
  "One column that stands for STATUS where its word has no room, or nil.
STATUS is from `roost--attention-status', and WAITING whether its task
waits for you.  By the colour `roost--status-face' gives it: a ? when
the task asks something of you, a ! when something went wrong, a disc
when it is your turn, and a dotted circle while its agent works or
starts.  Nil for the rest, which neither need you nor are at work:
stopped, merged, offline, and an agent that exited that you have seen."
  (pcase (roost--status-face status)
    ('roost-status-permission "?")
    ('roost-status-failed (propertize "!" 'face 'bold))
    ('roost-status-ready (car (roost--mark-glyphs)))
    ('roost-status-running (cdr (roost--mark-glyphs)))
    (_ (pcase status
         ("starting" (cdr (roost--mark-glyphs)))
         ("exited" (and waiting (propertize "!" 'face 'bold)))))))

(defconst roost--gap (propertize "\n" 'face '(:height 0.5))
  "A blank line half as tall as the rest, between groups and sections.")

(defun roost--table-lines (lines)
  "The indices of LINES that belong to Markdown tables.
A table is found by its delimiter row, such as \"--- | :---:\", with the
header row above it and the rows below that have a pipe."
  (let ((rows nil))
    (dotimes (index (length lines))
      (let ((line (aref lines index)))
        (when (and (string-search "|" line)
                   (string-match-p "\\`[ \t]*|?\\(?:[ \t]*:?-+:?[ \t]*|\\)*[ \t]*:?-+:?[ \t]*|?[ \t]*\\'"
                                   line))
          (when (and (> index 0) (string-search "|" (aref lines (1- index))))
            (push (1- index) rows))
          (push index rows)
          (let ((next (1+ index)))
            (while (and (< next (length lines)) (string-search "|" (aref lines next)))
              (push next rows)
              (setq next (1+ next)))))))
    rows))

(defun roost--prose (text)
  "TEXT with `roost-prose' on what reads as prose.
Lines laid out by column keep their font: Markdown tables, fenced code,
and lines indented as code."
  (let* ((text (copy-sequence text))
         (lines (vconcat (split-string text "\n")))
         (tables (roost--table-lines lines))
         (start 0)
         ;; The run of backticks or tildes that opened the code block
         ;; under way; only as long a run of the same closes it.  A fence
         ;; is indented three spaces at most, or it is indented code.
         (fence nil))
    (dotimes (index (length lines))
      (let* ((line (aref lines index))
             (end (+ start (length line))))
        (cond (fence
               (when (string-match-p (format "\\` \\{0,3\\}%s\\{%d,\\}[ \t]*\\'"
                                             (regexp-quote (substring fence 0 1)) (length fence))
                                     line)
                 (setq fence nil)))
              ((string-match "\\` \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
               (setq fence (match-string 1 line)))
              ((or (memq index tables) (string-match-p "\\`\\(?:[ \t]*|\\|    \\|\t\\)" line)))
              (t (add-face-text-property start end 'roost-prose t text)))
        (setq start (1+ end))))
    text))

(defun roost--text-width (string)
  "STRING's width in columns, as the windows showing this buffer show it.
Measured in pixels, so proportional text counts for what it takes up;
where frames show the buffer in different fonts, the widest measure
counts.  In a text frame, as in batch, this is STRING's width in columns."
  (let ((windows (or (seq-uniq (get-buffer-window-list nil nil t)
                               (lambda (a b) (eq (window-frame a) (window-frame b))))
                     (list (selected-window))))
        (remapping face-remapping-alist))
    ;; Measuring in a window showing this buffer puts the buffer's point
    ;; where the window's is, and a drawing in progress needs its own.
    (save-excursion
      (with-current-buffer (get-buffer-create " *roost text width*")
        ;; As `text-scale-adjust' leaves it in the buffer measured for, and
        ;; with no line numbers, which a global mode may have turned on.
        (setq-local face-remapping-alist remapping
                    display-line-numbers nil)
        (erase-buffer)
        (insert string)
        (apply #'max (mapcar (lambda (window)
                               (/ (float (car (buffer-text-pixel-size nil window t)))
                                  (window-font-width window)))
                             windows))))))

(defun roost--fit-width (string columns)
  "The longest start of STRING no wider than COLUMNS, as shown."
  (if (<= (roost--text-width string) columns)
      string
    (let ((low 0) (high (1- (length string))))
      (while (< low high)
        (let ((middle (/ (+ low high 1) 2)))
          (if (<= (roost--text-width (substring string 0 middle)) columns)
              (setq low middle)
            (setq high (1- middle)))))
      (substring string 0 low))))

(defun roost--truncate-width (string columns)
  "STRING cut with an ellipsis to fit COLUMNS, as shown.
The ellipsis takes the face of the text it follows."
  (if (<= (roost--text-width string) columns)
      string
    (let* ((ellipsis (propertize "…" 'face (get-text-property 0 'face string)))
           (start (string-trim-right
                   (roost--fit-width string (- columns (roost--text-width ellipsis))))))
      (concat start ellipsis))))

(defun roost--truncate-start (string columns)
  "STRING cut at its start with an ellipsis to fit COLUMNS, as shown."
  (if (<= (roost--text-width string) columns)
      string
    (let ((start 0))
      (while (and (< start (length string))
                  (> (roost--text-width (concat "…" (substring string start))) columns))
        (setq start (1+ start)))
      (concat "…" (substring string start)))))

(defun roost--words (line)
  "LINE split before each space, so that the pieces join to LINE again.
Each piece keeps LINE's text properties."
  (let ((start 0) (words nil))
    (while (and (< start (length line)) (string-match " " line (1+ start)))
      (push (substring line start (match-beginning 0)) words)
      (setq start (match-beginning 0)))
    (nreverse (cons (substring line start) words))))

(defun roost--wrap-width (text columns &optional most)
  "TEXT's lines broken at spaces to fit COLUMNS each, as shown.
TEXT's own line breaks are kept, as in lists and code.  A word wider
than COLUMNS, such as a URL, is broken within.  With MOST, stop after
more than MOST lines.  Return the lines."
  (let ((lines nil))
    (catch 'enough
      (let ((add (lambda (line)
                   (push line lines)
                   ;; A long reply is measured only as far as it shows.
                   (when (and most (> (length lines) most)) (throw 'enough nil)))))
        (dolist (source (split-string text "\n"))
          ;; A line broken off starts without spaces; TEXT's own lines
          ;; keep theirs, as list items are indented.
          (let ((line nil)
                (broken nil))
            ;; Each word after the first keeps the space before it, so
            ;; spaces keep their face, as their width depends on it.
            (dolist (word (roost--words source))
              (when (and broken (string-empty-p line))
                (setq word (string-trim-left word " +")))
              (let ((longer (concat line word)))
                (if (or (null line) (string-empty-p line) (<= (roost--text-width longer) columns))
                    (setq line longer)
                  (funcall add line)
                  (setq line (string-trim-left word " +")
                        broken t)))
              (while (> (roost--text-width line) columns)
                (let ((part (roost--fit-width line columns)))
                  (when (string-empty-p part) (setq part (substring line 0 1)))
                  (funcall add part)
                  (setq line (substring line (length part))
                        broken t))))
            (funcall add (or line ""))))))
    (nreverse lines)))

;;;; Status lights

(defcustom roost-animations nil
  "Whether the status light of an agent asking you something moves.
It fades out and back in, as it can't go on until you answer.  The rest
stay still, in colour while they wait for you, so motion always means an
agent is held up on you.
This needs Emacs 32's canvas images; without them the lights stay the
dots they are.  The motion pauses while no Emacs frame has focus.
Changed with `setopt' or Customize, it shows at once."
  :type 'boolean
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (roost--animations-changed)))

(declare-function canvas-refresh "image.c" (image &optional reload-data))

(defvar roost--lights (make-hash-table :test 'equal)
  "Status lights drawn on canvases, by (PLACE . KEY).
Each is a plist: :image, the canvas; :motion, as from
`roost--light-motion'; :color and :background, pixels; :buffer, where
it shows, or nil for the mode line; :phase, the step last drawn; and
:asked, when it was last asked for, as `float-time'.")

(defvar roost--lights-timer nil
  "Timer moving the status lights.")

(defconst roost--light-periods '((pulse . 2.0))
  "Seconds each motion of a status light takes.")

(defconst roost--light-depths '((pulse . 0.75))
  "How far towards its background each motion fades a status light.")

(defun roost--light-frame-p (frame)
  "Whether FRAME shows status lights: it is graphical.
A text frame shows each light's dot instead."
  (display-graphic-p frame))

(defun roost--animations-p ()
  "Whether status lights can move: on, with canvases and a frame to show them."
  (and roost-animations (fboundp 'canvas-refresh) (image-type-available-p 'canvas)
       (seq-some #'roost--light-frame-p (frame-list))))

(defun roost--light-window (buffer)
  "A visible window on a graphical frame showing BUFFER, or nil.
Only there do its lights show; a text frame shows their dots."
  ;; `visible' would look only at frames on the selected one's terminal.
  (seq-find (lambda (window)
              (let ((frame (window-frame window)))
                (and (roost--light-frame-p frame) (eq (frame-visible-p frame) t))))
            (get-buffer-window-list buffer nil t)))

(defun roost--light-motion (task)
  "How TASK's light moves, or nil if it rests.
Only an agent that can't go on without you moves: it pulses.  One that
finished or failed waits for you too, but nothing is held up, so its
light rests in colour, which costs nothing once drawn; a moving light
redraws, and Emacs redisplays, several times a second."
  (when (roost--blocked-p task) 'pulse))

(defun roost--light-pixel (color)
  "COLOR, a name or #RRGGBB, as an opaque ARGB32 pixel; mid-gray if unknown."
  (if-let* ((rgb (and (stringp color) (color-values color))))
      (logior #xFF000000 (ash (ash (nth 0 rgb) -8) 16) (ash (ash (nth 1 rgb) -8) 8) (ash (nth 2 rgb) -8))
    #xFF808080))

(defvar roost--light-shapes (make-hash-table :test 'equal)
  "Each pixel's distance from the middle of a light, by (WIDTH . HEIGHT).")

(defun roost--light-shape (width height)
  "The distance of each pixel of a WIDTH by HEIGHT light from its middle."
  (or (gethash (cons width height) roost--light-shapes)
      (let ((shape (make-vector (* width height) 0.0))
            (cx (/ width 2.0))
            (cy (/ height 2.0)))
        (dotimes (y height)
          (dotimes (x width)
            (aset shape (+ x (* y width))
                  (sqrt (+ (expt (- (+ x 0.5) cx) 2) (expt (- (+ y 0.5) cy) 2))))))
        (puthash (cons width height) shape roost--light-shapes))))

(defun roost--light-draw (light phase)
  "Draw LIGHT at PHASE, from 0 to 1, of its motion.
A disc, smoothed at its edge, that while moving fades towards its
background and back, whole at the start of each cycle.  Canvases have
no transparency, so it paints its background too.  Plain arithmetic,
cheap even when Roost runs uncompiled."
  (let* ((image (plist-get light :image))
         (pixels (plist-get (cdr image) :data))
         (width (plist-get (cdr image) :data-width))
         (height (plist-get (cdr image) :data-height))
         (shape (roost--light-shape width height))
         (color (plist-get light :color))
         (background (plist-get light :background))
         (motion (plist-get light :motion))
         ;; From 0 at the start of a cycle to 1 halfway, and back.
         (wave (- 0.5 (* 0.5 (cos (* 2 float-pi phase)))))
         (level (- 1 (* (alist-get motion roost--light-depths 0) wave)))
         (radius (min 3.5 (- (/ (min width height) 2.0) 1)))
         (edge (+ radius 0.5))
         (br (logand (ash background -16) 255)) (bg (logand (ash background -8) 255)) (bb (logand background 255))
         (dr (- (logand (ash color -16) 255) br)) (dg (- (logand (ash color -8) 255) bg)) (db (- (logand color 255) bb)))
    (fillarray pixels background)
    (dotimes (i (length pixels))
      (let ((d (aref shape i)))
        (when (< d edge)
          (let ((cover (* level (min 1.0 (- edge d)))))
            (aset pixels i (logior #xFF000000
                                   (ash (round (+ br (* cover dr))) 16)
                                   (ash (round (+ bg (* cover dg))) 8)
                                   (round (+ bb (* cover db)))))))))
    (when (fboundp 'canvas-refresh)
      (canvas-refresh image 'reload-data))))

(defconst roost--light-steps 20
  "Steps a light's motion takes per cycle.
A light is redrawn only when its step changes, and each redraw makes
Emacs redisplay its window, so fewer steps cost less.")

(defun roost--light-phase (motion)
  "Where in MOTION a light is now, from 0 to 1, in whole steps."
  (let ((period (or (alist-get motion roost--light-periods) 1.0)))
    (/ (float (floor (* roost--light-steps (/ (mod (float-time) period) period))))
       roost--light-steps)))

(defun roost--light (place key motion face background &optional buffer)
  "The canvas showing the status light of KEY at PLACE, made or updated.
MOTION is as from `roost--light-motion', FACE the status face and
BACKGROUND the face behind the light.  BUFFER is where it shows, nil
for the mode line."
  (let* ((id (cons place key))
         (light (gethash id roost--lights))
         ;; One image serves every frame showing BUFFER, so it is measured
         ;; in a graphical one that shows it, or any graphical one.
         (frame (or (when-let* ((window (and buffer (roost--light-window buffer))))
                      (window-frame window))
                    (seq-find #'roost--light-frame-p (cons (selected-frame) (frame-list)))
                    (selected-frame)))
         (width (* 2 (frame-char-width frame)))
         (height (max 8 (if (eq frame (selected-frame)) (default-line-height) (frame-char-height frame))))
         ;; A plain face, such as a running agent's, has the default one.
         (color (roost--light-pixel (face-foreground face frame 'default)))
         ;; A face without a background shows the default one: a theme
         ;; can leave `margin' so, as modus-themes does for no fringe.
         (back (roost--light-pixel (face-background background frame 'default))))
    (unless (and light
                 (= width (plist-get (cdr (plist-get light :image)) :data-width))
                 (= height (plist-get (cdr (plist-get light :image)) :data-height)))
      ;; `create-image' names each canvas itself.  It is drawn a pixel
      ;; for a pixel: scaled, it would outgrow its columns, and Emacs
      ;; draws only part of a scaled canvas.
      (setq light (list :image (create-image (make-vector (* width height) back) 'canvas t
                                             :data-width width :data-height height
                                             :scale 1 :ascent 'center)
                        :motion nil :color nil :background nil :buffer nil :phase nil :asked nil))
      (puthash id light roost--lights))
    (let ((changed (not (and (eql color (plist-get light :color))
                             (eql back (plist-get light :background))
                             (eq motion (plist-get light :motion))))))
      (plist-put light :color color)
      (plist-put light :background back)
      (plist-put light :motion motion)
      (plist-put light :buffer buffer)
      (plist-put light :asked (float-time))
      (when changed
        (plist-put light :phase (roost--light-phase motion))
        (roost--light-draw light (plist-get light :phase))))
    (when motion (roost--lights-start))
    (plist-get light :image)))

(defun roost--status-shape (status waiting)
  "The shape that stands for STATUS, from `roost--attention-status'.
WAITING is whether its task waits for you.  Colour says whether a task
wants you; the shape says what its agent is doing, and says the first
again to those who can't tell the colours apart: `asks' for an agent
held up on you, `wrong' for one that failed, `turn' for one that
finished, `working', `starting', `stopped', `merged', `offline', and
`idle' for the rest, which wait for nothing."
  (pcase status
    ((or "permission" "prompt") 'asks)
    ((or "failed" "crashed" "error" "ci failed") 'wrong)
    ((or "ready" "interrupted" "to merge" "comments" "conflicts") 'turn)
    ((or "running" "background") 'working)
    ("starting" 'starting)
    ("stopped" 'stopped)
    ("merged" 'merged)
    ("offline" 'offline)
    ("exited" (if waiting 'wrong 'idle))
    (_ 'idle)))

(defun roost--svg-colour (colour)
  "COLOUR, a name as Emacs knows it, as #RRGGBB, which an SVG image knows.
Emacs's own names, such as the grey70 of `shadow' where no theme sets
it, are not all ones SVG has.  Mid-grey for one that can't be read."
  (if-let* ((rgb (and (stringp colour) (ignore-errors (color-name-to-rgb colour)))))
      (apply #'color-rgb-to-hex (append rgb '(2)))
    "#808080"))

(defvar roost--status-shapes (make-hash-table :test 'equal)
  "The images of `roost--status-shape-image', by (SHAPE COLOUR WIDTH HEIGHT).")

(defun roost--status-shape-image (shape face)
  "An image of SHAPE, from `roost--status-shape', in FACE's colour, or nil.
A column wide and no taller than a line of text, so that it stands
where a status's dot does and moves nothing.  Nil where `roost-decorate'
is off or the display draws no such image; then the dot stands."
  (when (and (roost--decorated-p) (display-images-p) (image-type-available-p 'svg)
             (require 'svg nil t))
    (let* ((colour (roost--svg-colour (face-foreground face nil 'default)))
           (width (default-font-width))
           (height (default-font-height))
           (key (list shape colour width height)))
      (or (gethash key roost--status-shapes)
          (let* ((svg (svg-create width height))
                 (cx (/ width 2.0))
                 (cy (/ height 2.0))
                 ;; As wide as a column allows, with a little air each side.
                 (r (* 0.44 width))
                 (line (max 1.0 (* 0.15 width)))
                 (stroke (list :fill "none" :stroke colour :stroke-width line
                               :stroke-linecap "round" :stroke-linejoin "round")))
            (pcase shape
              ;; A disc: yours to look at.
              ('turn (svg-circle svg cx cy r :fill colour))
              ;; A disc in a ring: it can't go on until you answer.
              ('asks (svg-circle svg cx cy (* 0.4 r) :fill colour)
                     (apply #'svg-circle svg cx cy (- r (/ line 2)) stroke))
              ;; As the mark before what is wrong in a task's panel.
              ('wrong (svg-polygon svg (list (cons cx (- cy r))
                                             (cons (+ cx r) (+ cy (* 0.8 r)))
                                             (cons (- cx r) (+ cy (* 0.8 r))))
                                   :fill colour :stroke colour :stroke-width (* 0.5 line)
                                   :stroke-linejoin "round"))
              ;; Three quarters of a ring, as a wheel that turns.
              ('working (let ((ring (- r (/ line 2))))
                          (apply #'svg-circle svg cx cy ring
                                 :stroke-dasharray (format "%.2f %.2f" (* 1.5 float-pi ring)
                                                           (* 2 float-pi ring))
                                 stroke)))
              ;; A ring of dots: not there yet.
              ('starting (let ((ring (- r (/ line 2))))
                           (apply #'svg-circle svg cx cy ring
                                  :stroke-dasharray (format "0.01 %.2f" (/ (* 2 float-pi ring) 6))
                                  stroke)))
              ;; Two bars: paused, and yours to resume.
              ('stopped (dolist (x (list (- cx (* 0.45 r)) (+ cx (* 0.45 r))))
                          (apply #'svg-line svg x (- cy (* 0.75 r)) x (+ cy (* 0.75 r)) stroke)))
              ;; A tick: its work is in.
              ('merged (apply #'svg-polyline svg
                              (list (cons (- cx r) (+ cy (* 0.1 r)))
                                    (cons (- cx (* 0.3 r)) (+ cy (* 0.8 r)))
                                    (cons (+ cx r) (- cy (* 0.7 r))))
                              stroke))
              ;; A dash: its host can't be reached.
              ('offline (apply #'svg-line svg (- cx r) cy (+ cx r) cy stroke))
              ;; A small dot: nothing to do here.
              (_ (svg-circle svg cx cy (* 0.45 r) :fill colour)))
            ;; A pixel for a pixel: scaled, it would outgrow its column.
            (puthash key (svg-image svg :ascent 'center :scale 1) roost--status-shapes))))))

(defun roost--status-light (task place &optional inline)
  "TASK's status dot at PLACE: a moving light when `roost--animations-p'.
The light shows in the window's left margin, which no highlight covers,
and takes no column of the text; with INLINE, it shows in place of the
dot.  Otherwise this is the dot, in TASK's status face."
  (let* ((status (roost--attention-status task))
         (face (roost--status-face status)))
    (if (not (roost--animations-p))
        (let ((dot (propertize "●" 'face face)))
          ;; Where the display draws them, a shape of its own for each
          ;; kind of status, in place of the dot.
          (if-let* ((shape (roost--status-shape-image
                            (roost--status-shape status (roost--waiting-p task)) face)))
              (propertize dot 'display shape)
            dot))
      ;; The margin has a face of its own since Emacs 31.
      (let ((image (roost--light place (roost--key task) (roost--light-motion task) face
                                 (if (and (not inline) (facep 'margin)) 'margin 'default)
                                 (current-buffer))))
        ;; The dot keeps its face for a text frame, which shows no image.
        (if inline
            (propertize "●" 'face face 'display image 'roost-light (cons place (roost--key task)))
          (propertize "●" 'face face 'display `((margin left-margin) ,image)))))))

(defun roost--light-behind (id face)
  "Paint the light ID over FACE's background where it shows, if it isn't already."
  (when-let* ((light (gethash id roost--lights))
              (window (roost--light-window (plist-get light :buffer)))
              (back (roost--light-pixel (face-background face (window-frame window) 'default)))
              ((not (eql back (plist-get light :background)))))
    (plist-put light :background back)
    (roost--light-draw light (or (plist-get light :phase) 0.0))))

(defun roost--mode-line-light-check ()
  "Forget the mode line's light once no mode line has asked for it lately.
Redraws don't evaluate mode lines again, so while the light is there
they are made to, and one that shows it asks for it."
  (when-let* ((light (gethash '(mode-line . waiting) roost--lights)))
    (if (> (- (float-time) (plist-get light :asked))
           (* 2 (max roost-watch-interval roost-watch-unfocused-interval)))
        (remhash '(mode-line . waiting) roost--lights)
      (force-mode-line-update t))))

(defun roost--lights-forget (place keys)
  "Forget the lights at PLACE of tasks other than KEYS, and those of dead buffers."
  (let (stale)
    (maphash (lambda (id light)
               (when (or (and (equal (car id) place) (not (member (cdr id) keys)))
                         (when-let* ((buffer (plist-get light :buffer)))
                           (not (buffer-live-p buffer))))
                 (push id stale)))
             roost--lights)
    (dolist (id stale) (remhash id roost--lights))))

(defvar-local roost--light-margin nil
  "A list of the left margin this buffer had before status lights widened it.
Nil while they haven't; the margin itself can be nil, meaning none.")

(defun roost--light-margins (&optional none)
  "Give the windows showing this buffer a margin for status lights.
A margin at least as wide is kept, and the one the buffer had comes back
once the lights are off, or with NONE, which says the buffer shows no
lights.  A window that shows the buffer later gets its margin then."
  (let ((on (and (not none) (roost--animations-p)))
        (had roost--light-margin))
    (if on
        (add-hook 'window-buffer-change-functions #'roost--light-margins-shown nil t)
      (remove-hook 'window-buffer-change-functions #'roost--light-margins-shown t))
    (when (or on had)
      (cond ((and on (not had))
             (setq roost--light-margin (list left-margin-width)
                   left-margin-width (max (or left-margin-width 0) 2)))
            ((not on)
             (setq left-margin-width (car had)
                   roost--light-margin nil)))
      (dolist (window (get-buffer-window-list nil nil t))
        ;; A text frame shows no lights, so its windows keep the margin.
        (let* ((left (or (if (and on (not (roost--light-frame-p (window-frame window))))
                             (car roost--light-margin)
                           left-margin-width)
                         0))
               (width (and (> left 0) left)))
          (unless (eql (car (window-margins window)) width)
            (set-window-margins window left (cdr (window-margins window)))
            ;; Emacs keeps a side window's width only while its text is as
            ;; wide as when it was shown, which the margin changes.
            (when (window-preserved-size window t)
              (window-preserve-size window t t))))))))

(defun roost--animations-changed ()
  "Show a change of `roost-animations' at once, in the buffers that show.
Lights are made again, or let go with their margins; hidden buffers
change when they show."
  (clrhash roost--lights)
  (when (timerp roost--lights-timer)
    (cancel-timer roost--lights-timer)
    (setq roost--lights-timer nil))
  (roost--redraw)
  (force-mode-line-update t))

(defun roost--light-margins-shown (window)
  "Give WINDOW the margin for lights, if it has started showing this buffer.
The hook runs, with this buffer current, for a window that stopped
showing it too; that one is left alone."
  (when (eq (window-buffer window) (current-buffer))
    (roost--light-margins)))

(defun roost--lights-start ()
  "Start moving the status lights, if they aren't."
  (unless (timerp roost--lights-timer)
    (setq roost--lights-timer (run-at-time 0 nil #'roost--lights-tick))))

(defun roost--light-wait (motion)
  "Seconds until a light in MOTION reaches its next step."
  (let ((step (/ (or (alist-get motion roost--light-periods) 1.0) roost--light-steps)))
    ;; Just past the step, so that its phase has moved on.
    (+ (- step (mod (float-time) step)) 0.002)))

(defun roost--lights-tick ()
  "Move the status lights that show, while Emacs has focus.
It runs again when the next of them is due to move, or while no frame
has focus, after a second, to see whether one has.  It stops once none
that shows moves, or animations are off; drawing a buffer again when it
shows starts it again."
  (when (timerp roost--lights-timer)
    (cancel-timer roost--lights-timer))
  (setq roost--lights-timer nil)
  ;; Every wakeup costs a redisplay, which in a full configuration is
  ;; most of what moving lights cost; one in the background costs that
  ;; for nothing.
  (let ((next nil)
        (focused (seq-some #'frame-focus-state (frame-list))))
    (when (roost--animations-p)
      (maphash (lambda (id light)
                 (let ((buffer (plist-get light :buffer))
                       (motion (plist-get light :motion)))
                   (cond ((and buffer (not (buffer-live-p buffer)))
                          (remhash id roost--lights))
                         ((and motion (or (null buffer) (roost--light-window buffer)))
                          (setq next (min (or next 1.0) (if focused (roost--light-wait motion) 1.0)))
                          (let ((phase (roost--light-phase motion)))
                            ;; Only a light whose motion moved on is redrawn.
                            (when (and focused (not (eql phase (plist-get light :phase))))
                              (plist-put light :phase phase)
                              (roost--light-draw light phase)))))))
               roost--lights))
    (when next
      (setq roost--lights-timer (run-at-time next nil #'roost--lights-tick)))))

(defun roost--seconds-since (timestamp)
  "Whole seconds since TIMESTAMP, or nil if it is missing or unreadable."
  (when timestamp
    (ignore-errors
      (floor (max 0 (- (float-time) (float-time (date-to-time timestamp))))))))

(defun roost--elapsed (timestamp)
  "Format time since TIMESTAMP."
  (let ((seconds (roost--seconds-since timestamp)))
    (cond ((not seconds) "?")
          ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh%02dm" (/ seconds 3600) (/ (mod seconds 3600) 60)))
          (t (format "%dd" (/ seconds 86400))))))

(defun roost--changes (task &optional compact listed)
  "Git summary for TASK from the last full refresh.
COMPACT abbreviates commits ahead of and behind the integration branch,
and starts with the branch its worktree is on when not the task's,
whose changes these are; the task panel says that on a line of its own.
LISTED non-nil leaves out whether changes are uncommitted, for where
the files are listed under labels that say so."
  (let* ((size (roost--field task 'size))
         (diff (or (roost--field task 'diff) ""))
         (count (lambda (field pattern)
                  (cond (size (alist-get field size 0))
                        ((string-match (concat "\\([0-9]+\\) " pattern) diff)
                         (string-to-number (match-string 1 diff)))
                        (t 0))))
         (files (funcall count 'files "files? changed"))
         (added (funcall count 'added "insertions?"))
         (deleted (funcall count 'deleted "deletions?"))
         ;; Its size counts every file, but Git's statistics leave out
         ;; files it does not track yet.
         (new (if size 0 (seq-count (lambda (file) (alist-get 'untracked file)) (roost--field task 'files))))
         (ahead (or (roost--field task 'ahead) 0))
         (behind (or (roost--field task 'behind) 0))
         (commits (delq nil (list (when (> ahead 0) (format (if compact "↑%d" "%d ahead") ahead))
                                  (when (> behind 0) (format (if compact "↓%d" "%d behind") behind))))))
    (string-join
     (delq nil (list (when-let* ((compact)
                                 (branch (roost--other-branch task)))
                       (if (equal branch "HEAD") "detached" (concat "on " branch)))
                     (when (> files 0)
                       (concat (format "%d file%s" files (if (= files 1) "" "s"))
                               ;; Not for files with no lines, as a new one
                               ;; that is empty, or binary.
                               (unless (and size (= added 0) (= deleted 0))
                                 (format " +%d −%d" added deleted))))
                     (when (> new 0)
                       (if (> files 0) (format "%d new" new)
                         (format "%d new file%s" new (if (= new 1) "" "s"))))
                     (when (and (roost--field task 'dirty) (not listed)) "uncommitted")
                     (when commits (string-join commits (if compact " " " · ")))))
     " · ")))

(defun roost--large-change-p (task)
  "Whether TASK's changes reach any of the sizes in `roost-large-change'."
  (when-let* ((size (roost--field task 'size))
              ((> (alist-get 'files size 0) 0)))
    (seq-some (pcase-lambda (`(,key . ,count))
                (when-let* ((limit (plist-get roost-large-change key)))
                  (>= count limit)))
              `((:lines . ,(+ (alist-get 'added size 0) (alist-get 'deleted size 0)))
                (:files . ,(alist-get 'files size 0))
                (:directories . ,(length (alist-get 'directories size)))))))

(defun roost--size-summary (task)
  "TASK's changed lines, files and top-level directories, or nil if none.
As \"560 lines in 12 files, 4 top-level directories\"."
  (when-let* ((size (roost--field task 'size))
              (files (alist-get 'files size 0))
              ((> files 0)))
    (let ((lines (+ (alist-get 'added size 0) (alist-get 'deleted size 0)))
          (directories (length (alist-get 'directories size))))
      (concat (format "%d line%s in %d file%s" lines (if (= lines 1) "" "s") files (if (= files 1) "" "s"))
              (when (> directories 0)
                (format ", %d top-level director%s" directories (if (= directories 1) "y" "ies")))))))

(defun roost--large-change-mark (task)
  "The dim ± of TASK's row and panel when its changes are large, or nil.
See `roost-large-change'."
  (when (roost--large-change-p task)
    (propertize "±" 'face 'roost-dim
                'help-echo (concat "roost-large-change marks changes this large: "
                                   (roost--size-summary task)))))

(defun roost--large-change-echo (task)
  "A line saying what TASK's ± stands for, for a row's help, or \"\"."
  (if (roost--large-change-p task) (format "± %s\n" (roost--size-summary task)) ""))

(defun roost--spread (task)
  "Where TASK's changed files are, as \"In docs/, test/ and the top level\".
Nil when none are in a directory.  The top level holds those that are
in none."
  (when-let* ((size (roost--field task 'size))
              (directories (alist-get 'directories size)))
    (let ((top (when (alist-get 'topLevel size) '("the top level"))))
      (concat "In "
              (if (> (length directories) 4)
                  (string-join (cons (format "%d top-level directories" (length directories)) top) " and ")
                (let ((places (append (mapcar (lambda (directory) (concat directory "/")) directories) top)))
                  (concat (string-join (butlast places) ", ")
                          (when (cdr places) " and ")
                          (car (last places)))))))))

(defconst roost--changed-files-shown 12
  "How many changed files a task panel lists before summing up the rest.")

(defun roost--insert-changed-files (task width)
  "Insert TASK's changed files as buttons that show them, within WIDTH columns.
Those with changes not yet committed come first, under a label of their
own.  Each button shows all the file's changes since the task began."
  (let* ((files (roost--field task 'files))
         (uncommitted (lambda (file) (or (alist-get 'uncommitted file) (alist-get 'untracked file))))
         (room roost--changed-files-shown))
    (pcase-dolist (`(,label . ,group) `(("Uncommitted" . ,(seq-filter uncommitted files))
                                        ("Committed" . ,(seq-remove uncommitted files))))
      (when (and group (> room 0))
        (insert "  " (propertize label 'face 'roost-dim) "\n")
        (let* ((shown (seq-take group room))
               ;; Their counts in a column, two past the longest path shown.
               (column (and (roost--decorated-p)
                            (+ 4 (apply #'max
                                        (mapcar (lambda (file)
                                                  (min (string-width (alist-get 'path file))
                                                       (roost--changed-file-room file width)))
                                                shown))))))
          (dolist (file shown)
            (roost--insert-changed-file task file width column)))
        (setq room (max 0 (- room (length group))))))
    (when (length> files roost--changed-files-shown)
      (roost--insert-indented
       (substitute-command-keys
        (format "and %d more; \\<roost-task-info-mode-map>\\[roost-diff] shows every change"
                (- (length files) roost--changed-files-shown)))
       'roost-dim))))

(defun roost--changed-file-counts (file)
  "What FILE, one of a task's `files', changed: its lines, or that it is new."
  (cond ((alist-get 'untracked file) (propertize "new" 'face 'roost-diff-added))
        ((alist-get 'added file)
         (roost--fontify-changes (format "+%d −%d" (alist-get 'added file) (alist-get 'deleted file))))
        (t (propertize "binary" 'face 'roost-dim))))

(defun roost--changed-file-room (file width)
  "The columns FILE's path may take beside its counts, in WIDTH columns."
  (max 8 (- width 6 (string-width (roost--changed-file-counts file)))))

(defun roost--insert-changed-file (task file width &optional column)
  "Insert a button showing FILE, one of TASK's `files', within WIDTH columns.
Its counts start at COLUMN, if given, as the display can put them."
  (let* ((path (alist-get 'path file))
         (counts (roost--changed-file-counts file))
         (room (roost--changed-file-room file width)))
    (insert "  ")
    ;; Long paths keep their end, which names the file.
    (insert-text-button (if (> (string-width path) room)
                            (concat "…" (truncate-string-to-width
                                         path (string-width path)
                                         (- (string-width path) (1- room))))
                          path)
                        'follow-link t 'face 'roost-field
                        'help-echo (concat path "\nmouse-1: show its changes")
                        'action (lambda (_)
                                  ;; As for a command you give: a question
                                  ;; you left open would hold it back.
                                  (roost--quit-questions-left-open
                                   (lambda () (roost--diff-file task file)))
                                  (roost--diff-file task file)))
    (insert (if column (propertize "  " 'display `(space :align-to ,column)) "  ")
            counts "\n")))

(defun roost--agent-work-left (task)
  "The worktrees TASK's agent made that hold work not on the task's branch."
  (seq-filter (lambda (entry)
                (or (> (or (alist-get 'ahead entry) 0) 0) (alist-get 'dirty entry)))
              (roost--field task 'agentWork)))

(defun roost--insert-agent-work (task)
  "List the worktrees TASK's agent made for itself, each opening in Magit.
Claude Code makes them for its EnterWorktree tool and isolated subagents."
  (when-let* ((work (roost--field task 'agentWork)))
    (roost--insert-heading "Its agent's own worktrees")
    (dolist (entry work)
      (let ((path (alist-get 'path entry))
            (ahead (or (alist-get 'ahead entry) 0)))
        (insert "  ")
        (insert-text-button (or (alist-get 'branch entry) (file-name-nondirectory path))
                            'follow-link t 'face 'roost-field
                            'help-echo (concat path "\nmouse-1: open it in Magit")
                            'action (lambda (_)
                                      (let ((directory (roost--host-directory (roost--field task 'host) path)))
                                        (if (require 'magit nil t) (magit-status directory) (dired directory)))))
        (insert "  "
                (propertize (string-join
                             (or (delq nil (list (when (> ahead 0)
                                                   (format "%d commit%s not on this task's branch"
                                                           ahead (if (= ahead 1) "" "s")))
                                                 (when (alist-get 'dirty entry) "uncommitted changes")))
                                 '("nothing new"))
                             ", ")
                            'face (if (or (> ahead 0) (alist-get 'dirty entry)) 'roost-status-permission 'roost-dim))
                "\n")))))

(defvar-local roost--file-diff nil
  "Whether this Magit buffer is a file's diff that `roost--diff-file' made.")
(put 'roost--file-diff 'permanent-local t)

(defun roost--diff-file (task file)
  "Show how TASK has changed FILE, an entry of its `files'.
Each file has a buffer of its own, as Magit's diff of the file you visit
has while `magit-diff-buffer-file-locked' is on, so another file's diff
leaves this one open, behind it in the window a diff already has.  A
moved file's old path goes with it, or Git would show it all as new.  An
untracked file, with nothing to compare, is opened instead."
  (when (roost--field task 'worktreeMissing)
    (user-error "%s's worktree is gone" (roost--field task 'name)))
  (roost--in-task-frame
   task (lambda ()
          (let ((default-directory (roost--remote-directory task))
                (path (alist-get 'path file))
                (paths (delq nil (list (alist-get 'from file) (alist-get 'path file))))
                (rev (or (roost--fork-point task) "HEAD")))
            (if (and (not (alist-get 'untracked file)) (require 'magit nil t))
                (let ((display-buffer-overriding-action
                       '(display-buffer-reuse-mode-window (mode . magit-diff-mode))))
                  (roost--magit-setup)
                  ;; Since the fork point moved, as when the task was
                  ;; updated, the file's old buffer shows changes that
                  ;; aren't the task's.
                  (dolist (buffer (buffer-list))
                    (with-current-buffer buffer
                      (when (and roost--file-diff
                                 ;; By where it is now: updating past a
                                 ;; move leaves it no old path.
                                 (equal (car (last magit-buffer-diff-files)) path)
                                 ;; Magit 3 has the range under another name.
                                 (not (equal (if (boundp 'magit-buffer-diff-range)
                                                 magit-buffer-diff-range
                                               (bound-and-true-p magit-buffer-range))
                                             rev))
                                 (roost--task-in-directory default-directory (list task)))
                        (kill-buffer buffer))))
                  ;; What `magit-diff-working-tree' does, locked.  Magit 4
                  ;; takes the diff's type before that; Magit 3, as Debian
                  ;; and Ubuntu have it, doesn't.
                  (with-current-buffer
                      (let ((most (cdr (func-arity #'magit-diff-setup-buffer))))
                        (if (and (integerp most) (< most 6))
                            (magit-diff-setup-buffer rev nil nil paths magit-diff-buffer-file-locked)
                          (magit-diff-setup-buffer rev nil nil paths 'committed
                                                   magit-diff-buffer-file-locked)))
                    (setq roost--file-diff t)))
              (find-file (roost--worktree-file path)))))))

(defun roost--fontify-changes (changes)
  "Highlight the line counts and pending work in CHANGES."
  (let ((text (copy-sequence changes)))
    (dolist (rule '(("\\+[0-9]+" . roost-diff-added)
                    ("−[0-9]+" . roost-diff-removed)))
      (let ((start 0))
        (while (string-match (car rule) text start)
          (add-face-text-property (match-beginning 0) (match-end 0) (cdr rule) nil text)
          (setq start (match-end 0)))))
    text))

(defun roost--draft-error (what err command)
  "Say in the draft's header line that WHAT failed with ERR; COMMAND retries.
Only ERR's first line fits there; the echo area and *Messages* have it all."
  (let ((text (format " %s: %s · %s retries" what
                     (or (car (split-string err "\n" t "[ \t]+")) err)
                     (substitute-command-keys (format "\\[%s]" command)))))
    ;; Beside the draft's buttons, which send it again.
    (setq roost--draft-note text)
    (force-mode-line-update)))

(defun roost--one-line (string)
  "STRING with line breaks and tabs collapsed, for a table cell."
  (string-trim (replace-regexp-in-string "[\n\r\t]+" " " (or string ""))))

(defun roost--prompt-text (task)
  "TASK's prompt, or nil when it was created without one."
  (let ((prompt (roost--field task 'task)))
    (unless (or (null prompt) (equal prompt (roost--field task 'name))) prompt)))

(defun roost--latest-prompt (task)
  "What you last sent TASK's agent, or nil.
That is nil too while it is the prompt the task started with, for agents
whose hooks don't say, and for tasks recorded by older helpers."
  (let ((prompt (roost--field task 'lastPrompt)))
    (when (stringp prompt)
      (let ((prompt (string-trim prompt)))
        (unless (string-empty-p prompt) prompt)))))

(defconst roost--url-regexp
  "\\([*_~]*\\)\\(https?://[^[:space:]<>\"'`\ue000\ue001]+\\)"
  "A URL in what an agent wrote, and the Markdown emphasis that opens on it.
The URL's group takes in anything that follows it up to a space;
`roost--trim-url' takes off what belongs to the prose.")

(defun roost--trim-url (url emphasis)
  "URL without what follows it in the prose.
That is sentence punctuation, a closing bracket the URL did not open, as
around \"(see https://a.example)\", and the delimiters that close
EMPHASIS, the run that opened on the URL, as in \"**https://a.example**\"."
  (let (done)
    (while (and (not done) (> (length url) 0))
      (let ((last (aref url (1- (length url)))))
        (cond ((memq last '(?. ?, ?\; ?: ?! ??))
               (setq url (substring url 0 -1)))
              ((and (memq last '(?\) ?\] ?}))
                    (< (seq-count (apply-partially #'eq (pcase last (?\) ?\() (?\] ?\[) (_ ?{)))
                                  url)
                       (seq-count (apply-partially #'eq last) url)))
               (setq url (substring url 0 -1)))
              ((and (> (length emphasis) 0) (string-suffix-p emphasis url))
               (setq url (substring url 0 (- (length emphasis)))
                     emphasis ""))
              (t (setq done t))))))
  url)

(defun roost--link (label url)
  "LABEL as a button that opens URL in the browser."
  (make-text-button label nil 'face 'roost-field 'follow-link t 'help-echo url
                    'button-data url 'action #'browse-url))

(defun roost--link-urls (text &optional wrap)
  "TEXT with each URL in it a button that opens it.
What follows a URL in the prose is left out of it, see `roost--trim-url'.
WRAP, when given, is called on each button and returns what replaces it."
  (replace-regexp-in-string
   roost--url-regexp
   (lambda (match)
     (let* ((emphasis (match-string 1 match))
            (whole (match-string 2 match))
            (url (roost--trim-url whole emphasis)))
       (concat emphasis
               (funcall (or wrap #'identity) (roost--link url url))
               (substring whole (length url)))))
   text t t))

(defun roost--strip-markdown (text &optional links)
  "TEXT without Markdown emphasis delimiters and the backticks of inline code.
Delimiters are removed only where they wrap text, so identifiers such as
snake_case_name and expressions such as a * b are kept, and so is
everything inside inline code.  A Markdown link shows only its text.
With LINKS, that text and each URL are buttons that open the URL."
  (let ((kept nil)
        (text (or text "")))
    (cl-flet ((keep (string)
                ;; Set STRING aside from the emphasis below.
                (push string kept)
                (format "\ue000%d\ue001" (1- (length kept))))
              (restore (string)
                (replace-regexp-in-string
                 "\ue000\\([0-9]+\\)\ue001"
                 (lambda (match)
                   (nth (- (length kept) 1 (string-to-number (substring match 1 -1))) kept))
                 string t t)))
      (setq text (replace-regexp-in-string
                  "\\(`+\\)\\([^`\n]\\|[^`\n][^\n]*?[^`\n]\\)\\1"
                  (lambda (match)
                    ;; A run of backticks closes at a run of the same length;
                    ;; one space inside each end is padding, as in `` `a` ``.
                    (let ((inner (match-string 2 match)))
                      (save-match-data
                        (when (string-match "\\` \\(.*\\) \\'" inner)
                          (setq inner (match-string 1 inner))))
                      (keep (if links (roost--link-urls inner) inner))))
                  text t t))
      (setq text (replace-regexp-in-string
                  ;; The URL may hold balanced parentheses, as Markdown
                  ;; allows, nested two deep.
                  (concat "\\[\\([^]\n]+\\)\\]"
                          "(\\(https?://\\(?:[^()[:space:]]\\|"
                          "(\\(?:[^()[:space:]]\\|([^()[:space:]]*)\\)*)\\)+\\))")
                  (lambda (match)
                    (let ((label (roost--strip-markdown (restore (match-string 1 match))))
                          (url (match-string 2 match)))
                      (keep (if links (roost--link label url) label))))
                  text t t))
      (when links
        (setq text (roost--link-urls text #'keep)))
      (let ((previous nil))
        (while (not (equal previous text))
          (setq previous text
                text (replace-regexp-in-string
                      (concat "\\(^\\|[^[:alnum:]*_]\\)"
                              "\\(\\*\\{1,3\\}\\|_\\{1,2\\}\\)"
                              "\\([^[:space:]]\\(?:[^\n]*?[^[:space:]]\\)??\\)"
                              "\\2\\($\\|[^[:alnum:]*_.]\\|\\.\\($\\|[[:space:]]\\)\\)")
                      "\\1\\3\\4" text))))
      (restore text))))

(defun roost--last-message (task)
  "TASK's latest agent reply with Markdown markers removed, or nil.
Its links and URLs are buttons that open them."
  (let ((message (roost--field task 'lastMessage)))
    (when (stringp message)
      (let ((text (string-trim (roost--strip-markdown message t))))
        (unless (string-empty-p text) text)))))

(defun roost--permission-request (task)
  "What TASK's agent asks you, as \"Asks to run make\", or nil."
  (when-let* (((equal (roost--field task 'status) "permission"))
              (request (roost--field task 'request))
              ((stringp request)))
    request))

(defun roost--last-message-summary (task)
  "First meaningful line of TASK's latest reply, or nil.
Empty lines, ATX and Setext headings, and lines without letters or digits
are skipped."
  (when-let* ((message (roost--field task 'lastMessage))
              ((stringp message)))
    (let ((lines (split-string message "\r?\n\\|\r")))
      (seq-some (lambda (line)
                  (let ((raw (string-trim line))
                        (next (string-trim (or (cadr (memq line lines)) ""))))
                    (and (not (string-match-p "\\`#\\{1,6\\}\\(?:[ \t]\\|\\'\\)" raw))
                         (not (and (not (string-empty-p raw))
                                   (string-match-p "\\`\\(?:=+\\|-+\\)\\'" next)))
                         (string-match-p "[[:alnum:]]" raw)
                         (string-trim (roost--strip-markdown raw)))))
                lines))))

(defun roost--evil-state (mode state)
  "Start MODE's buffers in Evil STATE when Evil is loaded.
Called from the mode bodies, before Evil sets up the new buffer.  Evil
keeps one process-wide registration per mode; a nil STATE removes it."
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state mode state)))

(defun roost--quiet-display ()
  "Turn off line numbers and wrapping that global modes enable in Roost buffers."
  (when (derived-mode-p 'roost-dashboard-mode 'roost-task-info-mode 'roost-compose-mode
                      'roost-send-mode 'roost-pr-mode 'roost-search-mode 'roost-doctor-mode
                      'roost-note-box-mode 'roost-workload-mode 'roost-attempts-mode)
    (display-line-numbers-mode -1)
    (when (derived-mode-p 'roost-dashboard-mode 'roost-search-mode 'roost-attempts-mode)
      (visual-line-mode -1)
      (setq truncate-lines t))))

(defun roost--menu-applies-p (command)
  "Whether COMMAND applies to the task at point, for its menu entry.
With no task at point, the command asks which, so it applies, unless
there are no tasks at all."
  (let ((task (ignore-errors (roost--task-at-point))))
    (if task (roost--action-applies-p task command) (and (roost-tasks) t))))

(defconst roost--task-menu-items
  '(["Open agent terminal" roost-open-task :active (roost--menu-applies-p 'roost-open-task)]
    ["Shell beside agent" roost-shell :active (roost--menu-applies-p 'roost-shell)]
    ["Browse files" roost-files :active (roost--menu-applies-p 'roost-files)]
    ["Send prompt…" roost-send :active (roost--menu-applies-p 'roost-send)]
    "---"
    ["Review in Magit" roost-review :active (roost--menu-applies-p 'roost-review)]
    ["Diff the task's changes" roost-diff :active (roost--menu-applies-p 'roost-diff)]
    ["Mark as looked at" roost-mark-looked :active (roost--menu-applies-p 'roost-mark-looked)]
    ["Bring up to date" roost-update :active (roost--menu-applies-p 'roost-update)]
    ["Compare attempts" roost-compare-attempts :active (roost--menu-applies-p 'roost-compare-attempts)]
    "---"
    ["Pull request…" roost-pr :active (roost--menu-applies-p 'roost-pr)]
    ["Merge and retire…" roost-merge-retire :active (roost--menu-applies-p 'roost-merge-retire)]
    ["Retire or discard…" roost-retire :active (roost--menu-applies-p 'roost-retire)]
    ["Forget…" roost-forget :active (roost--menu-applies-p 'roost-forget)]
    ["Discard…" roost-discard :active (roost--menu-applies-p 'roost-discard)]
    "---"
    ["Stop…" roost-stop :active (roost--menu-applies-p 'roost-stop)]
    ["Resume" roost-resume :active (roost--menu-applies-p 'roost-resume)]
    ["Details" roost-task-info :active (roost--menu-applies-p 'roost-task-info)]
    ["Rename…" roost-rename :active (roost--menu-applies-p 'roost-rename)]
    ["Branch to merge into…" roost-retarget :active (roost--menu-applies-p 'roost-retarget)]
    ["Copy attach command" roost-copy-attach-command
     :active (roost--menu-applies-p 'roost-copy-attach-command)])
  "Menu items acting on the task at point.")

(easy-menu-define roost-task-menu nil
  "Actions on the selected Roost task."
  (cons "Roost task" roost--task-menu-items))

;;;; Task panel

(defvar transient--original-buffer)

(defun roost--dispatch-task ()
  "The task `roost-dispatch' acts on, or nil when it will ask.
Transient formats the menu in a temporary buffer; the task comes from
the buffer the menu was opened from."
  (with-current-buffer (if (buffer-live-p transient--original-buffer)
                           transient--original-buffer
                         (current-buffer))
    (ignore-errors (roost--task-at-point))))

(defun roost--dispatch-task-description ()
  "Heading for `roost-dispatch' naming the task its commands act on.
Below it, as in the task panel, what to do next, naming the key that
does it in this menu."
  (if-let* ((task (roost--dispatch-task)))
      (concat (format "Task %s (%s)" (propertize (roost--field task 'name) 'face 'roost-title)
                      (roost--row-word task))
              (when-let* ((next (roost--next-step task t)))
                (concat "\n" next)))
    "Task (chosen when needed)"))

(defun roost--dispatch-inapt-p (command)
  "Whether COMMAND, in the menu, does not apply to the menu's task.
With no task at all, none of the task commands do."
  (if-let* ((task (roost--dispatch-task)))
      (not (roost--action-applies-p task command))
    (null (roost-tasks))))

;; A predicate for each task entry of the menu, such as
;; `roost--stop-inapt-p': older transient doesn't say which entry it asks about.
(dolist (command '(roost-open-task roost-shell roost-files roost-send roost-task-info roost-review
                   roost-diff roost-mark-looked roost-update roost-pr roost-merge-retire roost-retire roost-forget
                   roost-stop roost-resume roost-goto-note roost-rename roost-retarget roost-compare-attempts))
  (defalias (intern (format "roost--%s-inapt-p" (string-remove-prefix "roost-" (symbol-name command))))
    (lambda () (roost--dispatch-inapt-p command))
    (format "Whether `%s' does not apply to the task of `roost-dispatch'." command)))

(defun roost--agent-running-p (task)
  "Whether TASK's agent is running, as last seen."
  (if (assq 'live task)
      (roost--field task 'live)
    (not (member (roost--field task 'status) '("stopped" "crashed" "exited")))))

(defun roost--action-applies-p (task command)
  "Whether COMMAND makes sense for TASK as last seen.
Its host would refuse the rest, or there is nothing for them to do.
Unknown Git statistics count as making sense."
  (let ((worktree (not (roost--field task 'worktreeMissing)))
        (ahead (roost--field task 'ahead))
        ;; All its work, not a pull request merged before its latest commits.
        (merged (roost--landed task))
        ;; The host retires and merges only a task whose agent is not at work.
        (active (member (roost--field task 'status) '("starting" "running" "permission" "background"))))
    (pcase command
      ('roost-shell (and worktree (not (member (roost--field task 'status) '("stopped" "crashed")))))
      ((or 'roost-files 'roost-review 'roost-diff 'roost-mark-looked 'roost-update) worktree)
      ((or 'roost-send 'roost-stop) (roost--agent-running-p task))
      ('roost-resume (and worktree (not (roost--agent-running-p task))))
      ;; A conversation's branch is Roost's own, with nothing to propose or merge.
      ('roost-pr (and worktree (not (roost--conversation-p task))
                      (or (roost--field task 'pr) (not (eql ahead 0)))))
      ;; Merged, the task's branch may be, but not work on another branch
      ;; there, which `m' merges once the task's has it.
      ('roost-merge-retire (and (not (roost--conversation-p task))
                                (or (not merged) (roost--other-branch task)) (not (eql ahead 0)) (not active)
                                (not (roost--agent-work-left task))))
      ;; Retires the task, or discards work merged nowhere.
      ('roost-retire (and (not active) (not (roost--agent-work-left task))))
      ('roost-goto-note (and worktree (roost--task-notes task) t))
      ('roost-retarget (not (roost--conversation-p task)))
      ;; A terminal attaches to an agent's window, while there is one.
      ('roost-copy-attach-command (and (roost--field task 'live) t))
      ;; With the other attempts at its prompt, while there are any.
      ('roost-compare-attempts (and (roost--attempts task) t))
      (_ t))))

(defun roost--next-step (task &optional menu beside)
  "What to do next with TASK, as a line naming its key, or nil.
MENU non-nil means the line is for `roost-dispatch', away from the
task panel's list of the agent's own worktrees.  BESIDE non-nil means
the agent's terminal is on screen: a question there is answered there,
where RET would pick the agent's default answer, so no key is named."
  (let* ((key (lambda (key) (propertize key 'face 'roost-key)))
         (status (roost--attention-status task))
         ;; As GitHub said last, or as its host recorded.
         (state (roost--pr-state task))
         (merged (eq state 'merged))
         (retire (lambda ()
                   (concat (if merged "Its pull request is merged; " "Its work is merged; ")
                           (funcall key "x") " retires it"))))
    (cond
     ((equal status "permission")
      (if beside "Answer it in its terminal"
        (concat "Answer it in its terminal: " (funcall key "RET"))))
     ((equal status "prompt")
      (if beside "It may be waiting at a startup prompt in its terminal, such as folder trust"
        (concat "It may be waiting at a startup prompt, such as folder trust: " (funcall key "RET"))))
     ((roost--field task 'worktreeMissing)
      (concat "Its worktree is gone: " (funcall key "x") " retires it if its work is merged, "
              (funcall key "X") " forgets it"))
     ;; Whether its agent is still there or not.
     ((equal status "merged") (funcall retire))
     ((equal status "error")
      (concat "Its last turn failed; open it to try its last prompt again: " (funcall key "RET")))
     ((member status roost--pr-turns) (roost--pr-next-step task key))
     ((equal status "conflicts") (roost--conflict-next-step task key))
     ((member status '("stopped" "crashed"))
      (concat (funcall key "RET") " or " (funcall key "s") " resumes its conversation"
              (when-let* ((others (roost--crashed-with task)))
                (format ", and offers the %s that crashed on %s"
                        (if (cdr others) (format "%d others" (length others)) "other one")
                        (roost--host-label (roost--field task 'host))))))
     ((not (roost--agent-running-p task))
      (concat (funcall key "RET") " shows its last output; " (funcall key "s") " resumes its conversation"))
     ((member status '("running" "background" "starting")) nil)
     ((equal (roost--status-name task) "interrupted")
      (concat "You stopped its last turn; tell it what to do instead: " (funcall key "e")))
     ((roost--field task 'merging)
      (concat "Finish merging " (or (roost--field task 'integrationBranch) "its branch")
              " into it in Magit: " (funcall key "r")))
     ((roost--field task 'dirty)
      (concat "Review and commit its changes in Magit: " (funcall key "r")))
     ((roost--agent-work-left task)
      (concat "Its agent left work in a worktree of its own: merge it into this task in Magit, or remove it"
              ;; The panel lists those worktrees, with buttons, below this line.
              (when menu (concat "; " (funcall key "i") " shows it"))))
     ;; Its host won't merge or retire it there, but a pull request from
     ;; there is the one to follow.
     ((roost--other-branch task)
      (if (equal (alist-get 'state (roost--worktree-pr task)) "OPEN")
          (roost--pr-next-step task key)
        (roost--other-branch-step task key)))
     ;; As for one you haven't looked at since its agent finished.
     ((roost--landed task) (funcall retire))
     ((consp (roost--conflicts task)) (roost--conflict-next-step task key))
     (merged (concat "Its pull request is merged, but not its commits since: " (funcall key "m") " merges them, or "
                     (funcall key "P") " opens a pull request"))
     ((memq state '(open draft)) (roost--pr-next-step task key))
     ((and (numberp (roost--field task 'ahead)) (> (roost--field task 'ahead) 0))
      (concat (funcall key "m") " merges it, or " (funcall key "P") " opens a pull request")))))

;;;###autoload (autoload 'roost-dispatch "roost" nil t)
(transient-define-prefix roost-dispatch ()
  "Show Roost's commands.
Task commands act on the task at point, in the dashboard, a task panel,
terminal or worktree, or ask which task."
  [:description roost--dispatch-task-description
   ["Work"
    ("RET" "Agent's terminal" roost-open-task :inapt-if roost--open-task-inapt-p)
    ("t" "Shell" roost-shell :inapt-if roost--shell-inapt-p)
    ("f" "Files" roost-files :inapt-if roost--files-inapt-p)
    ("e" "Send prompt" roost-send :inapt-if roost--send-inapt-p)
    ("i" "Details" roost-task-info :inapt-if roost--task-info-inapt-p)
    ("R" "Rename" roost-rename :inapt-if roost--rename-inapt-p)
    ("B" "Branch to merge into" roost-retarget :inapt-if roost--retarget-inapt-p)]
   ["Review"
    ("r" "Magit" roost-review :inapt-if roost--review-inapt-p)
    ("D" "Diff" roost-diff :inapt-if roost--diff-inapt-p)
    ("v" "Mark looked at" roost-mark-looked :inapt-if roost--mark-looked-inapt-p)
    ("u" "Bring up to date" roost-update :inapt-if roost--update-inapt-p)
    ("'" "Go to note" roost-goto-note :inapt-if roost--goto-note-inapt-p)
    ("=" "Compare attempts" roost-compare-attempts :inapt-if roost--compare-attempts-inapt-p)]
   ["Finish"
    ("P" "Pull request" roost-pr :inapt-if roost--pr-inapt-p)
    ("m" "Merge and retire" roost-merge-retire :inapt-if roost--merge-retire-inapt-p)
    ("x" "Retire or discard" roost-retire :inapt-if roost--retire-inapt-p)
    ("X" "Forget" roost-forget :inapt-if roost--forget-inapt-p)]
   ["Agent"
    ("K" "Stop" roost-stop :inapt-if roost--stop-inapt-p)
    ("s" "Resume" roost-resume :inapt-if roost--resume-inapt-p)]]
  ["Roost"
   [("c" "New task" roost-new-task)
    ("C" "New conversation" roost-new-conversation)
    ("n" "Next waiting" roost-next-waiting)
    ("l" "Switch task" roost-switch-task)
    ("/" "Search conversations" roost-search)]
   [("S" "Dashboard" roost-dashboard)
    ("w" "Workload" roost-workload)
    ("g" "Refresh" roost-refresh)]
   [("b" "Sidebar" roost-sidebar-mode)
    ("I" "Task panel" roost-task-panel-mode)
    ("!" "Setup check" roost-doctor)]])

(defvar-keymap roost-task-info-mode-map
  :doc "Actions on the task shown in this buffer."
  "h" #'roost-dispatch
  "?" #'roost-dispatch
  "RET" #'roost-open-task
  "r" #'roost-review
  "D" #'roost-diff
  "v" #'roost-mark-looked
  "f" #'roost-files
  "t" #'roost-shell
  "e" #'roost-send
  "s" #'roost-resume
  "K" #'roost-stop
  "x" #'roost-retire
  "m" #'roost-merge-retire
  "P" #'roost-pr
  "X" #'roost-forget
  "u" #'roost-update
  "R" #'roost-rename
  "B" #'roost-retarget
  "=" #'roost-compare-attempts
  "I" #'roost-task-panel-mode
  ;; Commands beyond this task, as in the dashboard and sidebar.
  "n" #'roost-next-waiting
  "l" #'roost-switch-task
  "/" #'roost-search
  "c" #'roost-new-task
  "C" #'roost-new-conversation
  "b" #'roost-sidebar-mode
  "S" #'roost-dashboard
  "w" #'roost-workload
  "q" #'roost-task-info-quit
  "g" #'roost-task-info-refresh)

(easy-menu-define roost-task-info-menu roost-task-info-mode-map
  "Menu for a Roost task panel."
  (cons "Roost" roost--task-menu-items))

(define-derived-mode roost-task-info-mode special-mode "Roost Task"
  "A task's next step, prompt, changes and details.
Status is the last observation from the task's host.
\\{roost-task-info-mode-map}"
  (setq-local truncate-lines nil
              ;; A docked panel is narrower than the default threshold of 50.
              truncate-partial-width-windows nil
              word-wrap t
              ;; As in `visual-line-mode', wrapped lines need no fringe arrows.
              fringe-indicator-alist (cons '(continuation nil nil)
                                           (default-value 'fringe-indicator-alist))
              ;; Docked, it has no mode line: the cursor and a highlight
              ;; show only while you are in it.
              cursor-in-non-selected-windows nil)
  (add-hook 'post-command-hook #'roost--mark-selection nil t)
  (add-hook 'window-selection-change-functions #'roost--selection-changed nil t)
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (add-hook 'window-size-change-functions #'roost--task-info-resized nil t)
  (roost--evil-state 'roost-task-info-mode roost-evil-state)
  (roost--quiet-display))

(defvar-local roost--beside-terminal nil
  "Non-nil if this task panel was last drawn with its agent's terminal on screen.")

(defvar-keymap roost--clicked-key-map
  :doc "A click on a key a view names, and the words that go with it."
  "<mouse-1>" #'roost-click-key)

(defun roost-click-key (event)
  "Do what the key clicked in EVENT does where it is named.
A question you left open in the minibuffer is quit first, as it would
take one the key's command asks."
  (interactive "e")
  (mouse-set-point event)
  (let ((command (get-text-property (point) 'roost-key-command))
        (position (point)))
    (unless (commandp command)
      (user-error "Nothing to do here"))
    (roost--quit-questions-here (lambda ()
                                  (goto-char (min position (point-max)))
                                  (call-interactively command)))
    (call-interactively command)))

(defun roost--key-at-p (position)
  "Whether the text at POSITION names a key, in a key's face."
  (or (memq 'roost-key (ensure-list (get-text-property position 'face)))
      (memq 'help-key-binding (ensure-list (get-text-property position 'face)))
      (eq (get-text-property position 'font-lock-face) 'help-key-binding)))

(defun roost--clickable-keys (map)
  "Make each key the current buffer names that MAP binds clickable.
A click runs the key's command, as the key would.  With the key go the
words after it up to a comma, colon, semicolon, bracket, dot or \"or\",
as in \"m merges it\", or else those before it back to a semicolon,
bracket, dot or \"or\", as in \"Finish it in Magit: r\"."
  (let ((inhibit-read-only t)
        (pos (point-min))
        (taken (point-min)))
    (while (< pos (point-max))
      (let ((next (min (next-single-char-property-change pos 'face)
                       (next-single-char-property-change pos 'font-lock-face))))
        (if (not (roost--key-at-p pos))
            (setq pos next)
          (let ((end pos))
            (while (and (< end (point-max)) (roost--key-at-p end))
              (setq end (min (next-single-char-property-change end 'face)
                             (next-single-char-property-change end 'font-lock-face))))
            (when-let* ((key (buffer-substring-no-properties pos end))
                        (command (ignore-errors (keymap-lookup map key)))
                        ((commandp command))
                        ((not (text-property-not-all pos end 'button nil))))
              (let* ((limit (save-excursion (goto-char end) (line-end-position)))
                     (after (save-excursion
                              (goto-char end)
                              (let ((stop (if (re-search-forward "[,;:()·.]\\| or " limit t)
                                              (match-beginning 0)
                                            limit))
                                    (p end))
                                (while (and (< p stop) (not (roost--key-at-p p)))
                                  (setq p (1+ p)))
                                (goto-char p)
                                (skip-chars-backward " " end)
                                (point))))
                     (words (string-match-p "[[:alpha:]]" (buffer-substring-no-properties end after)))
                     (start (if words
                                pos
                              (save-excursion
                                (goto-char pos)
                                (if (re-search-backward "[;()·.]\\| or " (max taken (line-beginning-position)) t)
                                    (goto-char (match-end 0))
                                  (goto-char (max taken (line-beginning-position))))
                                (skip-chars-forward " " pos)
                                (point))))
                     (stop (if words after end)))
                ;; Not over a button of the view's own.
                (when (text-property-not-all start stop 'button nil)
                  (setq start pos stop end))
                (add-text-properties start stop
                                     (list 'mouse-face 'highlight 'pointer 'hand
                                           'keymap roost--clicked-key-map
                                           'roost-key-command command
                                           'help-echo (format "mouse-1 or %s" key)))
                (setq taken stop)))
            (setq pos end)))))))

(defvar-local roost--near-terminal nil
  "Non-nil if this task panel was last drawn in a frame with its terminal.")

(defun roost--panel-beside-terminal-p (task &optional any)
  "Whether each window showing this task panel has TASK's terminal in its frame.
Then the panel leaves the agent's conversation to the terminal; one
window without it, such as in another frame, keeps the conversation.
With ANY, whether one window does: there, the panel names no key for
answering the agent, which RET in the terminal would answer instead."
  (when-let* ((windows (get-buffer-window-list nil 'nomini 'visible)))
    (funcall (if any #'seq-some #'seq-every-p)
             (lambda (window)
               (seq-some (lambda (other)
                           (with-current-buffer (window-buffer other)
                             (or (roost--terminal-shows-p task (list (roost--field task 'paneId)))
                                 ;; Just connected, before tmux says which pane
                                 ;; is active: the task's own session holds
                                 ;; only its agent's window.
                                 (and (fboundp 'tmux-control-active-pane)
                                      (null (tmux-control-active-pane))
                                      (when-let* ((shown (roost--terminal-task (current-buffer))))
                                        (equal (roost--key shown) (roost--key task)))))))
                         (window-list (window-frame window) 'nomini)))
             windows)))

(defun roost--redraw-moved-panels ()
  "Redraw the task panels whose agent's terminal came on or off screen."
  (dolist (window (window-list-1 nil 'nomini 'visible))
    (with-current-buffer (window-buffer window)
      (when-let* (((derived-mode-p 'roost-task-info-mode))
                  (task (gethash roost--buffer-task-key roost--tasks))
                  ((or (not (eq (not roost--beside-terminal)
                                (not (roost--panel-beside-terminal-p task))))
                       (not (eq (not roost--near-terminal)
                                (not (roost--panel-beside-terminal-p task t)))))))
        (roost--render-task-info)))))

(defun roost--narrowest-width (otherwise)
  "Columns in the narrowest window showing the current buffer, or OTHERWISE.
Windows showing one buffer can differ: a window on a graphical frame
has a margin for status lights, and one on a text frame doesn't."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows (apply #'min (mapcar #'roost--usable-width windows)) otherwise)))

(defun roost--task-info-width ()
  "Columns in the narrowest window showing the current task panel."
  (roost--narrowest-width 80))

(defun roost--usable-width (window)
  "Columns WINDOW shows on a line without truncating or continuing it.
Without fringes, as in a terminal, that is one less than its body width:
the last column is kept for the truncation mark."
  ;; `window-max-chars-per-line' selects WINDOW, which moves point in its
  ;; buffer to the window's point; a drawing in progress must keep its own.
  (save-excursion (window-max-chars-per-line window)))

(defun roost--task-info-resized (window)
  "Reflow the task panel after WINDOW is resized."
  (with-current-buffer (window-buffer window)
    (roost--render-task-info)))

(defun roost--insert-heading (title &optional note)
  "Insert section TITLE, followed by NOTE, when given.
Both quiet: the panel keeps bold for the task's name and colour for what
wants you, so that either shows from the terminal beside it."
  (insert roost--gap (propertize title 'face 'roost-label)
          (if note (concat "  " (propertize note 'face 'roost-dim)) "")
          "\n"))

(defun roost--insert-quiet (text)
  "Insert TEXT as a block of one quiet line, with no heading."
  (insert roost--gap (propertize text 'face 'roost-dim 'wrap-prefix "  ") "\n"))

(defun roost--insert-loud (text face)
  "Insert TEXT in FACE as a line of what is wrong with the task.
After a mark, with the lines it wraps to under its first word."
  (let ((line (concat "▲ " text "\n")))
    (add-face-text-property 0 (length line) face t line)
    ;; On a band of its colour, to the window's edge: it is the one
    ;; thing in the panel that is loud.
    (let ((tint (roost--tint face)))
      (when tint
        (add-face-text-property 0 (length line) (list :background tint :extend t) t line))
      ;; The band runs behind where its lines wrap to, too.
      (insert (propertize line 'wrap-prefix
                          (if tint (propertize "  " 'face (list :background tint)) "  "))))))

(defvar-local roost--panel-open nil
  "What a narrow task panel shows unfolded: `prompts' and `details' among them.
Beside a terminal each is one quiet line until you open it.")

(defvar-local roost--show-full-prompt nil
  "The task's prompt when the task panel shows it in full, or nil.")

(defvar-local roost--show-full-latest-prompt nil
  "Your latest prompt when the task panel shows it in full, or nil.
A different one starts folded when it arrives.")

(defvar-local roost--expanded-reply nil
  "The reply expanded in a compact panel, or nil.
A different reply starts collapsed when it arrives.")

(defconst roost--wide-panel 72
  "The fewest columns of a task panel that shows all it can.
A narrower one, as docked beside a terminal, cuts prompts and replies
short and leaves out the paths, the hint on notes and the footer's
longer lines.")

(defun roost--reply-preview (reply width &optional most)
  "The first MOST lines of REPLY, six unless given, as wrapped in WIDTH columns.
Return short replies unchanged.  Faces in REPLY, as from `roost--prose',
count in its width."
  (let* ((most (or most 6))
         (columns (max 12 (- width 2)))
         (lines (roost--wrap-width reply columns most)))
    (if (<= (length lines) most)
        reply
      (let ((last (string-trim-right (nth (1- most) lines))))
        (concat (mapconcat (lambda (line) (concat line "\n")) (seq-take lines (1- most)) "")
                (roost--truncate-width
                 (concat last (propertize "…" 'face (get-text-property (max 0 (1- (length last))) 'face last)))
                 columns))))))

(defun roost--prompt-preview (prompt)
  "The start of PROMPT for the task panel.
That is its first paragraph, cut to a few hundred characters.  A short
prompt is returned whole."
  (let* ((paragraph (car (split-string prompt "\n[ \t]*\n")))
         (preview (if (> (length paragraph) 400)
                      (concat (replace-regexp-in-string "[ \t\n]+[^ \t\n]*\\'" ""
                                                        (substring paragraph 0 400))
                              "…")
                    paragraph)))
    (if (equal (string-trim preview) (string-trim prompt)) prompt preview)))

(defun roost--insert-prompt (prompt what full width)
  "Insert PROMPT, only its start when long, with a button for the rest.
WHAT names the button, as for `roost--insert-toggle'.  FULL is the
variable that holds the prompt shown in full, or nil.  In a panel
WIDTH columns wide that is narrower than `roost--wide-panel', as beside
a terminal, its start is three lines: you wrote it, and what you don't
know yet comes below."
  (let* ((preview (roost--prose (roost--prompt-preview prompt)))
         (preview (if (< width roost--wide-panel) (roost--reply-preview preview width 3) preview)))
    ;; As text, ignoring faces.
    (cond ((equal preview prompt)
           (roost--insert-indented (roost--prose prompt)))
          ((equal (symbol-value full) prompt)
           (roost--insert-toggle "Collapse prompt" what (lambda () (set full nil)))
           (roost--insert-indented (roost--prose prompt)))
          (t
           (roost--insert-indented preview)
           (roost--insert-toggle "Show the whole prompt" what (lambda () (set full prompt)))))))

(defun roost--insert-indented (text &optional face)
  "Insert TEXT wrapped and indented under a heading, adding FACE."
  (let ((text (propertize (concat text "\n") 'line-prefix "  " 'wrap-prefix "  ")))
    (when face (add-face-text-property 0 (length text) face t text))
    (insert text)))

(defun roost--insert-toggle (label what action &optional flush)
  "Insert a button LABEL on a line of its own that calls ACTION and redraws.
WHAT names what it shows or hides, as `prompt': once redrawn, point is on
the button for WHAT, so that pressing it again takes the change back.
With FLUSH, at the left edge, as a line that folds a block."
  (let ((start (point)))
    (insert-text-button label 'follow-link t 'face 'roost-dim 'roost-toggle what
                        'action (lambda (_)
                                  (funcall action)
                                  (roost--render-task-info)
                                  (when-let* ((button (text-property-any (point-min) (point-max)
                                                                         'roost-toggle what)))
                                    (goto-char button)
                                    (when (eq (window-buffer) (current-buffer))
                                      (set-window-point nil button)))))
    (insert "\n")
    (unless flush (put-text-property start (point) 'line-prefix "  "))))

(defun roost--insert-reply-toggle (reply expanded)
  "Insert a button to expand REPLY, or collapse it when EXPANDED."
  (roost--insert-toggle (if expanded "Collapse reply" "Show the whole reply") 'reply
                        (lambda () (setq roost--expanded-reply (unless expanded reply)))))

(defun roost--window-places ()
  "Where each window showing the current buffer is, by line and column.
Pass the result to `roost--restore-window-places' after redrawing."
  (mapcar (lambda (window)
            (save-excursion
              (goto-char (window-point window))
              (list window (line-number-at-pos (window-start window))
                    (line-number-at-pos) (current-column))))
          (get-buffer-window-list nil nil t)))

(defun roost--restore-window-places (places)
  "Return windows to PLACES from `roost--window-places'."
  (pcase-dolist (`(,window ,start ,line ,column) places)
    (when (window-live-p window)
      (pcase-let ((`(,start . ,point)
                   (save-excursion
                     (goto-char (point-min))
                     (forward-line (1- start))
                     (cons (point)
                           (progn (goto-char (point-min))
                                  (forward-line (1- line))
                                  (move-to-column column)
                                  (point))))))
        (set-window-start window start t)
        ;; In the selected window, this moves point too.
        (set-window-point window point)))))

(defun roost--mark-place ()
  "Where the mark is, as (LINE . COLUMN), or nil without one.
Pass it to `roost--restore-mark' after redrawing, so a selection, say of
the agent's reply to copy, survives the redraws polls make."
  (when-let* ((mark (mark t)))
    (save-excursion (goto-char mark) (cons (line-number-at-pos) (current-column)))))

(defun roost--restore-mark (place)
  "Put the mark back at PLACE, from `roost--mark-place'."
  (when place
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- (car place)))
      (move-to-column (cdr place))
      (set-marker (mark-marker) (point)))))

(defvar-local roost--stale nil
  "The function redrawing this buffer, when it changed while no window showed it.")

(defun roost--render-visible (render)
  "Call RENDER to redraw the current buffer if a window shows it.
Otherwise call it once one does: polls redraw every few seconds, and
the panels of tasks you have looked at stay around."
  (if (get-buffer-window nil t)
      (progn (setq roost--stale nil)
             (funcall render))
    (setq roost--stale render)
    (add-hook 'window-buffer-change-functions #'roost--shown nil t)))

(defun roost--shown (window)
  "Redraw the Roost buffer WINDOW now shows, if it changed meanwhile.
For `window-buffer-change-functions'."
  (with-current-buffer (window-buffer window)
    (when-let* ((render roost--stale))
      (setq roost--stale nil)
      (funcall render))))

(defun roost--render-task-info ()
  "Update the current task panel from the cache, without changing focus.
Windows showing the panel keep their scroll position, and the mark stays."
  (let ((task (gethash roost--buffer-task-key roost--tasks))
        (inhibit-read-only t)
        (position (point))
        (mark (roost--mark-place))
        (places (roost--window-places)))
    (erase-buffer)
    (roost--lights-forget (cons 'panel (current-buffer)) (and task (list (roost--key task))))
    (if (not task)
        (insert "This task has been retired or is no longer available.\n")
      (roost--insert-task-info task))
    ;; Each key it names can be clicked too, with the words that go with it.
    (roost--clickable-keys roost-task-info-mode-map)
    (goto-char (min position (point-max)))
    (roost--restore-mark mark)
    (roost--restore-window-places places)
    ;; Redrawing removed the highlight with the text.
    (roost--mark-selection)))

(defun roost--insert-task-info (task)
  "Insert TASK's panel, block by block, from the top."
  (let* ((width (roost--task-info-width))
         ;; With the agent's terminal on screen, the conversation is its.
         (beside (setq roost--beside-terminal (roost--panel-beside-terminal-p task)))
         ;; Beside it in one frame, RET would answer the agent there.
         (next (roost--next-step task nil (setq roost--near-terminal
                                                (roost--panel-beside-terminal-p task t)))))
    (roost--insert-task-title task width)
    ;; First, and most of the time not there: what is wrong.
    (roost--insert-wrong task next)
    (when next
      (insert roost--gap
              ;; Which branch the worktree is on was just said, in its
              ;; colour: here, only how to put it right.
              (let ((said (and (roost--other-branch task)
                               (not (roost--field task 'worktreeMissing))
                               (format "Its worktree is on %s, not the task's branch: "
                                       (roost--branch-label (roost--other-branch task))))))
                (if (and said (string-prefix-p said next))
                    (substring next (length said))
                  next))
              "\n"))
    (unless beside
      (roost--insert-question task))
    ;; With room, what you asked for comes before what came of it.
    (unless (< width roost--wide-panel)
      (roost--insert-prompts task width))
    (let ((start (point)))
      (roost--insert-changes task width next)
      (roost--insert-merge-state task next)
      (when-let* ((overlaps (roost--overlaps task)))
        (roost--insert-indented (roost--changing-text overlaps "also changes" "also change") 'roost-dim))
      ;; With its worktree gone, no summary line sets these apart.
      (when (and (roost--field task 'worktreeMissing) (> (point) start))
        (save-excursion (goto-char start) (insert roost--gap))))
    (roost--insert-agent-work task)
    (roost--insert-status-notes task)
    (roost--insert-evidence task width beside)
    (roost--insert-issue task)
    (roost--insert-pull-request task)
    (if (>= width roost--wide-panel)
        (progn (roost--insert-details task width)
               (roost--insert-panel-keys task width))
      ;; Beside a terminal, which shows your prompts, and where the rest
      ;; rarely matters: the keys, then a quiet line for each.
      (roost--insert-panel-keys task width)
      (roost--insert-folded-prompts task width)
      (roost--insert-folded-details task width))))

(defun roost--insert-wrong (task next)
  "Insert what is wrong with TASK and wants you to act, under its title.
In colour, and most of the time nothing: the rest of the panel is plain
or dim, so colour in it is news, which shows from the terminal beside
it.  NEXT is the panel's next step, which comes below and says how to
put it right; what it says already is said once, there."
  (when (roost--field task 'worktreeMissing)
    (roost--insert-loud "The worktree is gone" 'roost-status-failed))
  (roost--insert-other-branch task next)
  (roost--insert-merge-state task next t)
  (when-let* ((error (roost--field task 'error)))
    (roost--insert-loud (concat "Last error: " error) 'roost-status-failed)))

(defun roost--insert-fold (label what)
  "Insert a quiet line, LABEL, that unfolds WHAT in a narrow panel."
  (roost--insert-toggle (concat "▸ " label) what (lambda () (cl-pushnew what roost--panel-open)) t))

(defun roost--insert-unfold (label what)
  "Insert the line, LABEL, that folds WHAT again, above it."
  (roost--insert-toggle (concat "▾ " label) what
                        (lambda () (setq roost--panel-open (delq what roost--panel-open))) t))

(defun roost--insert-folded-prompts (task width)
  "Insert TASK's prompts as one quiet line, in WIDTH columns, or unfolded.
The line is your latest prompt, or the one the task began with when you
have sent none since: where you left off, should the terminal have
scrolled it away."
  (when-let* ((prompt (or (roost--latest-prompt task) (roost--prompt-text task))))
    (if (memq 'prompts roost--panel-open)
        (progn (insert roost--gap)
               (roost--insert-unfold "Prompts" 'prompts)
               (roost--insert-prompts task width t))
      (roost--insert-fold (truncate-string-to-width (roost--one-line prompt) (max 8 (- width 3)) nil nil "…")
                          'prompts))))

(defun roost--insert-folded-details (task width)
  "Insert where TASK's work lives as one quiet line, or unfolded, in WIDTH columns."
  ;; Apart from the prompts above it, when those are unfolded.
  (when (and (memq 'prompts roost--panel-open)
             (or (roost--latest-prompt task) (roost--prompt-text task)))
    (insert roost--gap))
  (if (memq 'details roost--panel-open)
      (progn (roost--insert-unfold "Details" 'details)
             (roost--insert-details task width t))
    (roost--insert-fold "Details" 'details)))

(defun roost--insert-task-title (task width)
  "Insert TASK's name, its status and where it runs, in WIDTH columns."
  (let* ((name (propertize (roost--field task 'name) 'face 'roost-title))
         (word (roost--row-word task))
         (state (concat (roost--status-light task (cons 'panel (current-buffer)) t)
                        (propertize (concat " " word)
                                    'face (roost--status-word-face (roost--attention-status task)))
                        ;; Not since it merged, or its pull request
                        ;; came to wait on you, but since its agent last moved;
                        ;; nor for one you've seen, which isn't seen "for" a time.
                        (unless (member word (append '("merged" "conflicts" "seen") roost--pr-turns))
                          (propertize (format " for %s" (roost--elapsed (roost--field task 'updatedAt)))
                                      'face 'roost-dim)))))
    ;; The status keeps to one line, below the name when both don't fit:
    ;; at the window's right edge, where the display can put it.  One
    ;; that waits on you is on a tint of its colour, from a space before.
    (let ((tint (and (roost--waiting-p task) (roost--status-face (roost--attention-status task))))
          (apart (> (+ (roost--text-width name) 3 (roost--text-width state)) width)))
      (insert name
              (cond (apart "\n")
                    ((roost--decorated-p)
                     (concat (propertize "  " 'display
                                         `(space :align-to (- right ,(+ 2 (roost--text-width state)))))
                             (if tint (roost--tinted " " tint) " ")))
                    (t "   "))
              (if tint (roost--tinted state tint) state)
              "\n")))
  (let ((where (concat (propertize (format "%s · %s · %s" (roost--host-label (roost--field task 'host))
                                           (roost--project-name task)
                                           (or (roost--field task 'agent) "claude"))
                                   'face 'roost-dim)
                       "\n")))
    ;; Ruled off from what follows, which is what the panel is for.
    (insert (roost--ruled where)))
  ;; While it works, what it is doing, which the status word can't say.
  (when-let* ((doing (roost--activity task)))
    (insert (propertize (concat (truncate-string-to-width doing (max 8 (1- width)) nil nil "…") "\n")
                        'face 'roost-dim 'help-echo doing))))

(defun roost--activity (task)
  "What TASK's agent is doing now, as its host last heard, or nil.
The tool it last started, as \"Running make test\" or \"Editing
ledger.py\", while it works: an agent that reports none says nothing."
  (when-let* ((doing (roost--field task 'activity))
              ((stringp doing))
              ((not (string-empty-p doing)))
              ((member (roost--field task 'status) '("running" "background")))
              ((roost--field task 'live)))
    doing))

(defun roost--insert-question (task)
  "Insert what TASK's agent asks your permission for, if it does."
  (when-let* ((request (roost--permission-request task)))
    (roost--insert-heading "Waiting for your answer")
    (roost--insert-indented (roost--prose request))))

(defun roost--insert-prompts (task width &optional under)
  "Insert the prompt TASK began with and the one you last sent, in WIDTH columns.
UNDER means under the line that folds them, which is their heading."
  (when-let* ((prompt (roost--prompt-text task)))
    (unless under (roost--insert-heading "Prompt"))
    (roost--insert-prompt prompt 'prompt 'roost--show-full-prompt width))
  ;; Where you left off, which the terminal may have scrolled away.
  (let ((prompt (roost--latest-prompt task)))
    ;; Another one, or none, leaves the next to come folded.
    (unless (equal prompt roost--show-full-latest-prompt)
      (setq roost--show-full-latest-prompt nil))
    (when prompt
      (roost--insert-heading "Your latest prompt")
      (roost--insert-prompt prompt 'latest-prompt 'roost--show-full-latest-prompt width))))

(defun roost--insert-changes (task width next)
  "Insert what TASK changed, in WIDTH columns.
NEXT is the panel's next step, which may already say some of it."
  (let ((changes (roost--changes task nil (roost--field task 'files))))
    ;; No heading: what it changed is most of the panel, and its place
    ;; says so.  How much, quietly, and the files under it plainly.
    (unless (roost--field task 'worktreeMissing)
      (let ((summary (copy-sequence
                      (cond ((not (assq 'diff task)) "Refreshing…")
                            ((string-empty-p changes) "No changes yet")
                            (t (concat (when-let* ((mark (roost--large-change-mark task))) (concat mark " "))
                                       (roost--fontify-changes changes)))))))
        ;; Under the faces of its line counts, which keep theirs.
        (add-face-text-property 0 (length summary) 'roost-dim t summary)
        (insert roost--gap (propertize summary 'wrap-prefix "  ") "\n"))))
  (when-let* (((not (roost--field task 'worktreeMissing)))
              (spread (roost--spread task)))
    (roost--insert-indented spread))
  ;; Those of its last full refresh, which no diff can show now.
  (unless (roost--field task 'worktreeMissing)
    (roost--insert-changed-files task width))
  (roost--insert-since-looked task next)
  (roost--insert-notes-line task width))

(defun roost--insert-notes-line (task width)
  "Insert what TASK's review notes come to, or how to write one, in WIDTH columns."
  (if-let* ((notes (roost--notes-summary task)))
      (roost--insert-indented notes)
    ;; Taught in a wide panel, as the line on what ready means below;
    ;; beside a terminal, room goes to what changes.
    (when (and (>= width roost--wide-panel)
               (fboundp 'magit-status)
               (seq-some (lambda (file) (not (alist-get 'untracked file)))
                         (roost--field task 'files)))
      (roost--insert-indented
       (concat "In a file's diff, "
               (substitute-command-keys "\\<roost-magit-mode-map>\\[roost-note]")
               " writes a note for the agent")
       'roost-dim))))

(defun roost--insert-merge-state (task next &optional wrong)
  "Insert how TASK stands with the branch it merges into.
NEXT is the panel's next step, which may already say so.  With WRONG,
only what is wrong and wants you, for the top of the panel: a merge
under way, or one that would conflict.  Without, only the rest."
  (let ((integration (roost--field task 'integrationBranch)))
    (if-let* ((merging (roost--field task 'merging)))
        (when wrong
          (roost--insert-loud
           (substitute-command-keys
            (if-let* ((conflicts (alist-get 'conflicts merging)))
                (format "Merging %s into it conflicts in %s: resolve them and commit in Magit (\\<roost-task-info-mode-map>\\[roost-review]), or ask its agent to (\\[roost-send])."
                        integration (string-join conflicts ", "))
              (format "A merge of %s is under way in it: commit it in Magit (\\<roost-task-info-mode-map>\\[roost-review])."
                      integration)))
           'roost-status-permission))
      (cond
       ;; Said once: the next step may say it already.
       ((roost--names-key-p next "u"))
       ;; Nor would an update or a merge happen there.
       ((roost--other-branch task))
       ((consp (roost--conflicts task))
        (when wrong
          (roost--insert-loud
           (substitute-command-keys
            (format "Merging it into %s would conflict in %s: \\<roost-task-info-mode-map>\\[roost-update] merges %s into this task, to resolve them here first."
                    integration (roost--file-list (roost--conflicts task) 10) integration))
           'roost-status-permission)))
       ;; Not when it moved on by merging the task.
       ((and (not wrong) (> (or (roost--field task 'behind) 0) 0) (not (eq (roost--landed task t) t)))
        (roost--insert-indented
         (substitute-command-keys
          (format "%s has moved on; \\<roost-task-info-mode-map>\\[roost-update] merges it into this task before you merge the task back."
                  integration))
         'roost-dim))))))

(defun roost--insert-status-notes (task)
  "Insert what TASK's status leaves to explain."
  ;; How an agent ended, or why it waits, is the next step's, above.
  (pcase (roost--display-status task)
    ("offline"
     (roost--insert-indented "The host is unreachable; this is the last known state." 'roost-dim))
    ("starting"
     (when (equal (roost--field task 'agent) "codex")
       (roost--insert-indented
        (if (roost--field task 'programStatus)
            "Codex may be asking you to trust this folder or Roost's hooks; answer in its terminal. Sending prompts from Emacs works once it waits for one."
          "Codex reports status from its first turn. Open the terminal, review any hook or startup prompts, and enter the first prompt there; sending prompts from Emacs works after that.")
        'roost-dim)))))

(defun roost--insert-evidence (task width beside)
  "Insert what a merge of TASK would rest on, in WIDTH columns.
The easiest to check comes first: the agent's word comes last, as its
own.  BESIDE means the agent's terminal is on screen."
  (let ((evidence (roost--evidence-p task)))
    ;; Without a pull request, no results stand beside the agent's
    ;; reply, which the terminal shows rather than the panel.
    (when (and evidence (or (roost--pr-state (roost--pr-view task)) (not beside)))
      (roost--insert-checks task)
      (roost--insert-review-threads task width))
    (unless beside
      (roost--insert-latest-reply task width evidence))))

(defun roost--insert-latest-reply (task width evidence)
  "Insert the latest reply of TASK's agent, in WIDTH columns.
EVIDENCE means results stand above it, and its heading says whose it is."
  (when-let* ((reply (roost--last-message task))
              (reply (roost--prose reply)))
    (roost--insert-heading "Agent's latest reply" (when evidence "its own account"))
    (let* ((preview (if (< width roost--wide-panel) (roost--reply-preview reply width) reply))
           (expanded (equal reply roost--expanded-reply)))
      (unless expanded (setq roost--expanded-reply nil))
      (when (and expanded (not (equal preview reply)))
        (roost--insert-reply-toggle reply t))
      (roost--insert-indented (if expanded reply preview))
      (when (and (not expanded) (not (equal preview reply)))
        (roost--insert-reply-toggle reply nil)))))

(defun roost--insert-details (task width &optional under)
  "Insert where TASK's work lives, in WIDTH columns.
UNDER means under the line that folds it, which is its heading."
  (let ((base (roost--field task 'baseRef))
        (integration (roost--field task 'integrationBranch))
        (retarget (propertize "B" 'face 'roost-key)))
    (unless under (roost--insert-heading "Details"))
    (dolist (entry `(,@(unless (roost--conversation-p task)
                         ;; A conversation's branch is Roost's own, with nothing to merge.
                         `(("Branch" . ,(format "%s, from %s%s%s" (roost--field task 'branch) base
                                          ;; Where you see that it is the wrong one.
                                          (if (and integration (not (string-empty-p integration)))
                                              (format ", merges into %s (%s changes that)" integration retarget)
                                            (format " (%s gives it a branch to merge into)" retarget))
                                          (if-let* ((other (roost--other-branch task)))
                                              (format "; the worktree is on %s" (roost--branch-label other))
                                            "")))))
                     ;; One of several tasks a draft made from one prompt.
                     ,@(when-let* ((attempt (roost--attempt-detail task)))
                         `(("Attempt" . ,attempt)))
                     ;; Offered by an agent and started by you.
                     ,@(when (roost--field task 'parent)
                         `(("Started from" . ,(if-let* ((parent (roost--parent-task task)))
                                                  (roost--task-label parent)
                                                "a task Roost no longer has"))))
                     ,@(when-let* ((started (roost--started-tasks task)))
                         `(("Started" . ,(mapconcat #'roost--task-label started ", "))))
                     ,@(unless (< width roost--wide-panel)
                         `(("Worktree" . ,(roost--abbreviate-path (or (roost--field task 'worktree) "")
                                                                  (roost--field task 'host)))
                           ("Project" . ,(roost--abbreviate-path (or (roost--field task 'repo) "")
                                                                 (roost--field task 'host)))
                           ("Tmux" . ,(format "session %s on socket %s" (roost--field task 'session)
                                              (roost--field task 'socket)))
                           ("Conversation" . ,(or (roost--field task 'agentSession)
                                                  (roost--field task 'claudeSession)
                                                  "not recorded yet"))))))
      (if (< width roost--wide-panel)
          ;; Too narrow for a label column: the value goes below its label.
          (insert "  " (propertize (car entry) 'face 'roost-dim) "\n"
                  (propertize (concat (or (cdr entry) "unknown") "\n")
                              'line-prefix "  " 'wrap-prefix "  "))
        (insert (propertize (concat "  " (propertize (format "%-13s" (car entry)) 'face 'roost-dim)
                                    (or (cdr entry) "unknown") "\n")
                            'wrap-prefix (make-string 15 ?\s)))))))

(defun roost--quiet-but-keys (text)
  "TEXT dim, but for the keys it names, which keep their face.
So they look as keys do elsewhere, and can be clicked as those can."
  (let ((text (copy-sequence text)))
    (add-face-text-property 0 (length text) 'roost-dim t text)
    text))

(defun roost--insert-panel-keys (task width)
  "Insert the keys of TASK's panel, in WIDTH columns.
Beside a terminal, a row of the keys that open the task's other views,
the same for every task but for one that has no such view now: what to
do with the task next is the next step's, at the top.  With room, what
ready means, and the menu's key."
  (insert roost--gap
          (roost--quiet-but-keys
           (substitute-command-keys
            (if (< width roost--wide-panel)
                (concat "\\<roost-task-info-mode-map>"
                        (mapconcat (lambda (view) (format "\\[%s] %s" (car view) (cdr view)))
                                   (append (seq-filter (lambda (view) (roost--action-applies-p task (car view)))
                                                       '((roost-review . "Magit") (roost-files . "Files")
                                                         (roost-shell . "Shell")))
                                           '((roost-dispatch . "More")))
                                   "  "))
              (concat "Ready means the agent is waiting for you, not that the work is reviewed.\n"
                      "\\<roost-task-info-mode-map>\\[roost-dispatch] opens the menu · "
                      "\\[roost-task-info-refresh] refreshes · "
                      "\\[roost-task-info-quit] closes"))))
          "\n"))

(defun roost--task-label (task)
  "TASK's name, qualified by host when names collide.
Tasks with the same name on the same host are told apart by their IDs."
  (let* ((name (roost--field task 'name))
         (host (roost--field task 'host))
         (twins (seq-filter (lambda (other) (equal (roost--field other 'name) name))
                            (hash-table-values roost--tasks))))
    (cond ((length< twins 2) name)
          ((length< (seq-filter (lambda (other) (equal (roost--field other 'host) host)) twins) 2)
           (format "%s on %s" name (roost--host-label host)))
          (t (format "%s on %s (%s)" name (roost--host-label host)
                     (substring (roost--field task 'id) 0 6))))))

(defun roost--task-info-buffer-name (task)
  "Buffer name for TASK's panel; see `roost--task-label'."
  (format "*roost: %s*" (roost--task-label task)))

(defun roost--draft-buffer (kind variable task)
  "TASK's draft buffer of KIND, whose buffer-local VARIABLE holds its task.
A draft is found by its task rather than its name, so tasks with the
same name keep drafts of their own."
  (let ((key (roost--key task)))
    (or (seq-find (lambda (buffer)
                    (when-let* ((other (buffer-local-value variable buffer)))
                      (equal (roost--key other) key)))
                  (buffer-list))
        (generate-new-buffer (format "*roost %s: %s*" kind (roost--task-label task))))))

;;;###autoload
(defun roost-task-info (&optional task)
  "Show TASK's next step, prompt, changes, checks, latest reply and details."
  (interactive)
  (setq task (roost--choose task))
  (let ((buffer (roost--task-info-buffer task)))
    (if-let* ((window (get-buffer-window buffer)))
        (select-window window)
      (pop-to-buffer buffer))
    ;; Changes come from a full refresh; fetch them for this host now.
    (roost--refresh-host (roost--field task 'host) nil)))

(defun roost--task-info-buffer (task)
  "TASK's panel buffer, rendered."
  (let* ((key (roost--key task))
         (buffer (or (seq-find (lambda (buffer)
                                 (equal (buffer-local-value 'roost--buffer-task-key buffer) key))
                               (buffer-list))
                     (get-buffer-create (roost--task-info-buffer-name task)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-task-info-mode) (roost-task-info-mode))
      (setq roost--buffer-task-key key)
      (roost--render-task-info))
    buffer))

(defun roost--name-panels ()
  "Name each task panel for its task, as `roost--task-label' says now.
A panel's name depends on the other tasks' names too: tasks of one name
are told apart."
  (dolist (buffer (buffer-list))
    (when-let* (((eq (buffer-local-value 'major-mode buffer) 'roost-task-info-mode))
                (task (gethash (buffer-local-value 'roost--buffer-task-key buffer) roost--tasks))
                (name (roost--task-info-buffer-name task))
                ((not (equal name (buffer-name buffer)))))
      (with-current-buffer buffer (rename-buffer name t)))))

(defun roost-task-info-refresh ()
  "Refresh the task's status and Git statistics."
  (interactive)
  (if-let* ((task (gethash roost--buffer-task-key roost--tasks)))
      (roost--refresh-host (roost--field task 'host) nil)
    (roost-refresh)))

;;;; Dashboard

(defvar-keymap roost-dashboard-mode-map
  :doc "Task dashboard commands."
  "RET" #'roost-open-task
  "TAB" #'roost-dashboard-next-task
  "<backtab>" #'roost-dashboard-previous-task
  "j" #'roost-dashboard-next-task
  "k" #'roost-dashboard-previous-task
  "c" #'roost-new-task
  "C" #'roost-new-conversation
  "r" #'roost-review
  "D" #'roost-diff
  "v" #'roost-mark-looked
  "i" #'roost-task-info
  "I" #'roost-task-panel-mode
  "b" #'roost-sidebar-mode
  "l" #'roost-switch-task
  "f" #'roost-files
  "t" #'roost-shell
  "e" #'roost-send
  "s" #'roost-resume
  "K" #'roost-stop
  "x" #'roost-retire
  "m" #'roost-merge-retire
  "P" #'roost-pr
  "X" #'roost-forget
  "u" #'roost-update
  "R" #'roost-rename
  "B" #'roost-retarget
  "=" #'roost-compare-attempts
  "n" #'roost-next-waiting
  "/" #'roost-search
  "w" #'roost-workload
  ;; As in Magit, `h' and `?' show every command.
  "h" #'roost-dispatch
  "?" #'roost-dispatch
  "g" #'roost-refresh)

(easy-menu-define roost-dashboard-menu roost-dashboard-mode-map
  "Menu for the Roost dashboard."
  `("Roost"
    ["New task…" roost-new-task]
    ["Next task needing attention" roost-next-waiting]
    ["Switch task…" roost-switch-task]
    ["Refresh" roost-refresh]
    ["Sidebar" roost-sidebar-mode :style toggle :selected roost-sidebar-mode]
    ["Task panel beside terminal" roost-task-panel-mode
     :style toggle :selected roost-task-panel-mode]
    "---"
    ,@roost--task-menu-items))

(defvar-keymap roost--dashboard-row-map
  :doc "Mouse actions on a dashboard row."
  "<mouse-1>" #'roost-dashboard-mouse-open
  "<mouse-3>" #'roost-dashboard-mouse-menu)

(defvar-keymap roost--project-row-map
  :doc "Keys on a project the sidebar lists for a new task."
  "RET" #'roost-sidebar-new-task
  "X" #'roost-forget-project
  "<mouse-1>" #'roost-sidebar-new-task
  "<mouse-3>" #'roost-sidebar-project-menu)

(defvar-keymap roost--offer-row-map
  :doc "Keys on an offer the dashboard or sidebar lists under its task.
As a task's keys do for a task: open it, send its agent a prompt, and
finish with it.  The others act on the task it sits under."
  "RET" #'roost-open-offer
  "e" #'roost-offer-here
  "x" #'roost-offer-dismiss
  "<mouse-1>" #'roost-open-offer
  "<mouse-3>" #'roost-offer-mouse-menu)

(defconst roost--clicked-commands
  '(roost-dashboard-mouse-open roost-dashboard-mouse-menu roost-compose-open-task
    roost-sidebar-new-task roost-sidebar-project-menu roost-compose-submit roost-compose-cancel
    roost-open-offer roost-offer-mouse-menu
    roost-click-key roost-send-submit roost-send-cancel roost-send-attach
    roost-pr-submit roost-pr-submit-draft roost-pr-cancel)
  "Commands that clicks on Roost's rows and buttons run.")

;; With a menu open, Roost's or another package's, a click on a task's
;; row closes the menu and does what it does, rather than being refused
;; as none of the menu's keys.
(dolist (command roost--clicked-commands)
  (define-key transient-predicate-map (vector command) #'transient--do-exit))

(define-derived-mode roost-dashboard-mode special-mode "Roost"
  "Coding agent tasks across hosts, grouped by project.
Refreshes are asynchronous; rendering uses only cached state.
\\{roost-dashboard-mode-map}"
  (when roost-decorate (setq-local line-spacing roost--line-spacing))
  (setq-local truncate-lines t
              revert-buffer-function (lambda (&rest _) (roost-refresh)))
  (setq header-line-format
        (substitute-command-keys
         " \\<roost-dashboard-mode-map>\\[roost-open-task] open · \\[roost-new-task] new · \\[roost-next-waiting] next waiting · \\[roost-shell] shell · \\[roost-review] review · \\[roost-merge-retire] merge · \\[roost-task-info] details · \\[roost-dispatch] all commands"))
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (add-hook 'window-size-change-functions #'roost--dashboard-resized nil t)
  (roost--evil-state 'roost-dashboard-mode roost-evil-state)
  (roost--quiet-display))

(defun roost--dashboard-resized (window)
  "Reflow the dashboard after WINDOW is resized."
  (with-current-buffer (window-buffer window)
    (roost--render-dashboard)))

(defun roost--task-groups (tasks)
  "TASKS grouped by host and repository, as ((HOST REPO) TASK...) in display order."
  (let (groups)
    (dolist (task tasks)
      (let* ((key (list (roost--field task 'host) (roost--field task 'repo)))
             (group (assoc key groups)))
        (if group (push task (cdr group)) (push (list key task) groups))))
    (sort (mapcar (lambda (group)
                    (cons (car group)
                          (roost--under-parents
                           (roost--attempts-together
                            (sort (cdr group)
                                  (lambda (a b) (string< (or (roost--field a 'startedAt) "")
                                                         (or (roost--field b 'startedAt) ""))))))))
                  groups)
          (lambda (a b)
            (string< (format "%s %s" (roost--host-label (caar a)) (cadar a))
                     (format "%s %s" (roost--host-label (caar b)) (cadar b)))))))

;;;; Tasks agents offer, and the tasks you start from them

(defun roost--parent-task (task)
  "The task whose agent offered TASK, which you started, if Roost has it."
  (when-let* ((parent (roost--field task 'parent)))
    (gethash (list (roost--field task 'host) parent) roost--tasks)))

(defun roost--started-tasks (task)
  "The tasks TASK's agent offered and you started, oldest first."
  (sort (seq-filter (lambda (other) (eq (roost--parent-task other) task))
                    (hash-table-values roost--tasks))
        (lambda (a b) (string< (or (roost--field a 'startedAt) "")
                               (or (roost--field b 'startedAt) "")))))

(defconst roost--nesting-shown 3
  "How many levels of tasks started from others a view indents.")

(defun roost--nesting (task)
  "How many tasks up TASK was started from, as far as views indent it."
  (let ((depth 0) (seen (list task)))
    (while (and (< depth roost--nesting-shown)
                (setq task (roost--parent-task task))
                (not (memq task seen)))
      (push task seen)
      (cl-incf depth))
    depth))

(defun roost--nesting-indent (task)
  "The indent of TASK's row under the task it was started from."
  (make-string (* 2 (roost--nesting task)) ?\s))

(defun roost--under-parents (tasks)
  "TASKS in order, each followed by those it started that are among them."
  (let ((started (make-hash-table :test 'eq))
        (shown (make-hash-table :test 'eq))
        (among (make-hash-table :test 'eq))
        roots ordered)
    (dolist (task tasks)
      (puthash task t among))
    (dolist (task tasks)
      (let ((parent (roost--parent-task task)))
        (if (and parent (gethash parent among))
            (push task (gethash parent started))
          (push task roots))))
    (cl-labels ((walk (task)
                  (unless (gethash task shown)
                    (puthash task t shown)
                    (push task ordered)
                    (mapc #'walk (reverse (gethash task started))))))
      (mapc #'walk (nreverse roots))
      ;; Tasks each started from the other, which no record should say.
      (mapc #'walk tasks))
    (nreverse ordered)))

(defun roost--offers (task)
  "The offers TASK's agent made that wait for you, oldest first."
  (let ((offers (roost--field task 'offers)))
    (seq-filter (lambda (offer)
                  (and (consp offer)
                       (stringp (alist-get 'id offer)) (stringp (alist-get 'title offer))
                       (stringp (alist-get 'brief offer))))
                (if (listp offers) offers (append offers nil)))))

(defun roost--offer-project (task offer)
  "The project OFFER, of TASK's agent, is for when it isn't TASK's own, or nil.
As a local or TRAMP directory on TASK's host.  A conversation, which has
no project, offers tasks in yours."
  (when-let* ((project (alist-get 'project offer))
              ((stringp project))
              ((not (string-empty-p project))))
    (roost--remote-directory (cons (cons 'worktree project) task))))

(defun roost--offer-row (offer)
  "Where the row of OFFER, a task's key and an offer's ID, starts, if shown."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward 'roost-offer offer t)))
      (prop-match-beginning match))))

(defun roost--insert-offer-row (task offer line)
  "Insert LINE, the row of OFFER, which TASK's agent made, under TASK's."
  (let ((row (list 'roost-offer (list (roost--key task) (alist-get 'id offer))
                   'keymap roost--offer-row-map)))
    (insert (apply #'propertize line
                   'mouse-face 'highlight
                   'help-echo (format "%s offers: %s%s\n\n%s\n\nmouse-1: open it as a task draft · mouse-3: more"
                                      (roost--field task 'name) (alist-get 'title offer)
                                      (if-let* ((project (roost--offer-project task offer)))
                                          (format ", in %s" (roost--project-label project))
                                        "")
                                      (truncate-string-to-width (alist-get 'brief offer) 600 nil nil "…"))
                   row)
            ;; Without `mouse-face', so each row lights up alone.
            (apply #'propertize "\n" row))))

(defun roost--dashboard-offer-row (task offer layout width)
  "The dashboard line for OFFER, which TASK's agent made, in LAYOUT.
Under TASK's line, fitting WIDTH columns, and dim, as nothing waits on
it: its title, the word offer where a task's status goes, how long ago
it was made, and its brief, where a task's latest reply goes."
  (let* ((size (plist-get layout :name))
         (nested (concat (roost--nesting-indent task) "  "))
         ;; Within the name column, which keeps a letter of the title.
         (indent (substring nested 0 (min (length nested) (+ 2 (or (plist-get layout :indent) 0))
                                          (max 0 (1- size)))))
         (title (truncate-string-to-width (alist-get 'title offer) (max 1 (- size (length indent))) nil nil "…"))
         (at (alist-get 'at offer))
         (line (concat
                ;; Where a task's dot is, unless its light is in the margin.
                "  " (if (roost--animations-p) "" " ") " "
                indent title
                (make-string (max 0 (- size (length indent) (string-width title))) ?\s)
                "  " (truncate-string-to-width "offer" 11 nil ?\s) " "
                (truncate-string-to-width (if (stringp at) (roost--elapsed at) "") 6 nil ?\s "…") "  "
                ;; Past the columns only tasks fill.
                (make-string (+ (if (> (plist-get layout :pr) 0) (+ (plist-get layout :pr) 2) 0)
                                (if (plist-get layout :agent) 10 0)
                                (if (> (plist-get layout :changes) 0) (+ (plist-get layout :changes) 2) 0))
                             ?\s)))
         (room (- width (string-width line) 1)))
    (concat (propertize line 'face 'roost-dim)
            (when (> room 8)
              (roost--truncate-width
               (propertize (truncate-string-to-width (roost--one-line (alist-get 'brief offer)) (* 3 room)
                                                     nil nil "…")
                           'face '(roost-dim roost-prose))
               room)))))

(defun roost--sidebar-offer-row (task offer width)
  "The sidebar line for OFFER, which TASK's agent made, within WIDTH columns.
Under TASK's line, and dim, as nothing waits on it: its title, then the
word offer where a task's status goes.  Its brief is in its help-echo."
  (let* ((label "offer")
         (nested (concat (roost--nesting-indent task) "  "))
         ;; As far as leaves room for a letter of the title and the label.
         (indent (substring nested 0 (min (length nested) (max 0 (- width 1 2 (length label))))))
         (room (- width 1 (length indent)))
         (title (truncate-string-to-width (alist-get 'title offer) (max 1 (- room (length label) 1)) nil nil "…")))
    (propertize (concat " " indent title
                        (make-string (max 1 (- room (string-width title) (length label))) ?\s)
                        label)
                'face 'roost-dim)))

(defun roost--offer-at (&optional event)
  "The offer at point, or clicked in EVENT, and its task, as (TASK OFFER)."
  (when (mouse-event-p event)
    (mouse-set-point event))
  (pcase-let* ((`(,key ,id) (or (get-text-property (point) 'roost-offer) (user-error "No offer here")))
               (task (or (gethash key roost--tasks)
                         (user-error "That task is no longer listed; refresh with `g'")))
               (offer (or (seq-find (lambda (offer) (equal (alist-get 'id offer) id)) (roost--offers task))
                          (user-error "That offer no longer waits; refresh with `g'"))))
    (list task offer)))

(defun roost--take-offer (task offer &optional then)
  "Take OFFER, which TASK's agent made: it no longer waits under TASK.
Then call THEN, if given, once TASK's host has done it.  Not once TASK
went, as when you forgot its host while Do it here's prompt went: the
reply would bring it back, and its offers went with it."
  (when (gethash (roost--key task) roost--tasks)
    (roost--act task "take-offer" (list (cons 'offer (alist-get 'id offer)))
                (lambda (_task) (when then (funcall then)))
                (lambda (err)
                  (message "Roost could not take %s's offer %s: %s"
                           (roost--field task 'name) (alist-get 'title offer) err)))))

(defun roost-open-offer (&optional event)
  "Open the offer at point, or the one clicked in EVENT, as a new task draft.
The dashboard and sidebar list the offers a task's agent made under it.
Opening one takes it, so it no longer waits there.  The draft is in that
task's project, with its agent, starts from the branch that task merges
into, and is named and prompted as the agent offered it, to change as
you like.  Create leaves you where you are, and the task it makes shows
under the one that offered it."
  (interactive (list last-nonmenu-event))
  (pcase-let ((`(,task ,offer) (roost--offer-at event)))
    (let ((open (lambda () (roost--compose-offer task offer))))
      ;; A question left open would give back the windows it found,
      ;; without the draft, once it ended.
      (or (roost--quit-questions-left-open open)
          (funcall open)))))

(defun roost--compose-offer (task offer)
  "Open OFFER, which TASK's agent made, as a new task draft, and take it.
A draft that holds a prompt of yours, or says what became of a request
of its own, stays as it is, and so does the offer.  An offer's draft
starts anew, as a request asked before with the one it replaces would
be answered with that one's task."
  (when-let* ((buffer (get-buffer roost--compose-buffer)))
    (with-current-buffer buffer
      (when (or roost--compose-submitting roost--draft-note (not (string-empty-p (roost--compose-prompt))))
        (roost--pop-to-buffer-in-place buffer)
        (user-error "%s" (substitute-command-keys
                          "Create this draft (\\<roost-compose-mode-map>\\[roost-compose-submit]) or cancel it (\\[roost-compose-cancel]) first; the offer waits"))))
    (kill-buffer buffer))
  (let* ((elsewhere (roost--offer-project task offer))
         ;; In another project, it starts where that project's checkout is.
         (into (unless elsewhere (roost--field task 'integrationBranch))))
    (roost--compose nil (cons (alist-get 'brief offer) t) (or elsewhere (roost--project-directory task)))
    (with-current-buffer roost--compose-buffer
      (setq roost--compose-fields
            (thread-first roost--compose-fields
                          (plist-put :agent (or (roost--field task 'agent) roost-default-agent))
                          ;; By its full name, as a tag of the same name would
                          ;; otherwise stand for it.
                          (plist-put :base (and (stringp into) (not (string-empty-p into))
                                                (or (roost--field task 'integrationRef)
                                                    (concat "refs/heads/" into))))
                          (plist-put :integration (and (stringp into) (not (string-empty-p into)) into))
                          (plist-put :name (alist-get 'title offer))
                          (plist-put :parent (roost--key task))
                          (plist-put :offer (alist-get 'id offer))))
      (roost--compose-render)))
  ;; Once its draft is open, which holds all of it.
  (roost--take-offer task offer))

(defun roost-offer-here (&optional event)
  "Have the agent that made the offer at point, or clicked in EVENT, do it.
Its task gets the prompt Do this task here: “TITLE”, as `e' sends
one, and the offer no longer waits.  The agent wrote the brief, so the
title is all it needs."
  (interactive (list last-nonmenu-event))
  (pcase-let ((`(,task ,offer) (roost--offer-at event)))
    (when (roost--offer-project task offer)
      (user-error "%s is for %s, which %s isn't in; open it as a task there"
                  (alist-get 'title offer)
                  (roost--project-label (roost--offer-project task offer))
                  (roost--field task 'name)))
    (unless (roost--agent-running-p task)
      (user-error "%s's agent isn't running; resume it first" (roost--field task 'name)))
    (roost--send-text task (format "Do this task here: “%s”" (alist-get 'title offer))
                      (lambda (_task) (roost--take-offer task offer))
                      nil nil
                      ;; The same for the same offer, so that asking again,
                      ;; as after no reply, pastes it once.
                      (concat (roost--field task 'id) (alist-get 'id offer)))))

(defun roost-offer-dismiss (&optional event)
  "Dismiss the offer at point, or the one clicked in EVENT.
It no longer waits under its task, and nothing starts."
  (interactive (list last-nonmenu-event))
  (pcase-let ((`(,task ,offer) (roost--offer-at event)))
    (roost--take-offer task offer
                       (lambda () (message "Dismissed %s's offer %s"
                                           (roost--field task 'name) (alist-get 'title offer))))))

(easy-menu-define roost-offer-menu nil
  "Menu for an offer the dashboard or sidebar lists under its task."
  '("Offer"
    ["Open as a task draft" roost-open-offer]
    ["Do it here" roost-offer-here]
    ["Dismiss" roost-offer-dismiss]))

(defun roost-offer-mouse-menu (event)
  "Show what can be done with the offer clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (popup-menu roost-offer-menu event))

(defun roost--offers-sentence (task)
  "TASK's offers that wait, which go with it, as a sentence to ask after, or \"\"."
  (pcase (roost--offers task)
    ('nil "")
    (`(,offer) (format "Its offer %s goes with it.  " (alist-get 'title offer)))
    (offers (format "Its %d offers go with it.  " (length offers)))))

(defconst roost--row-words
  '("permission" "starting" "error" "failed" "crashed" "ci failed" "conflicts" "comments"
    "ready" "interrupted" "to merge" "exited" "merged" "running" "background" "stopped"
    "seen" "offline")
  "Each word a dashboard row can say, in the order its summary counts them.
What can't go on without you comes first, then what failed, what else
waits on you, and last what waits for nothing.")

(defun roost--row-word (task)
  "TASK's word, on its dashboard row and wherever else Roost names its state.
As `roost--display-status' has it, but \"seen\" for an agent you have
seen that waits for nothing, which the sidebar leaves without a word.
The task panel, the menu, `roost-switch-task' and search say it too."
  (if (equal (roost--attention-status task) "idle") "seen" (roost--display-status task)))

(defun roost--summary (tasks)
  "One-line count of TASKS by the word on their rows.
A count is in the colour of the most pressing of its tasks, as for
\"starting\" when one of them seems held at a startup prompt."
  (let ((counts (make-hash-table :test 'equal))
        (attention (make-hash-table :test 'equal)))
    (dolist (task tasks)
      (let ((word (roost--row-word task))
            (status (roost--attention-status task)))
        (cl-incf (gethash word counts 0))
        (unless (equal (gethash word attention) "prompt")
          (puthash word status attention))))
    (let* ((words (seq-filter (lambda (word) (gethash word counts))
                              ;; Words of statuses Roost doesn't know yet come last.
                              (seq-uniq (append roost--row-words (hash-table-keys counts)))))
           ;; A count in a status's colour is on a tint of it, from the
           ;; space before to the space after, where there is one.
           (tint (lambda (word)
                   (let ((face (roost--status-word-face (gethash word attention))))
                     (and (memq face '(roost-status-permission roost-status-failed)) face))))
           (line (mapconcat
                  (lambda (word)
                    (propertize (format "%d %s" (gethash word counts) word)
                                'face (roost--status-word-face (gethash word attention))
                                'roost-tint (funcall tint word)))
                  words (propertize " · " 'face 'roost-dim))))
      (roost--tint-marked line))))

(defun roost--tint-marked (line)
  "LINE with each run marked `roost-tint' on a tint of that face's colour.
The tint takes in the space before the run and the space after, which
pad it, and the mark is taken off."
  (let ((line (copy-sequence line))
        (pos 0))
    (while (setq pos (text-property-not-all pos (length line) 'roost-tint nil line))
      (let* ((face (get-text-property pos 'roost-tint line))
             (end (or (next-single-property-change pos 'roost-tint line) (length line)))
             (from (if (and (> pos 0) (eq (aref line (1- pos)) ?\s)) (1- pos) pos))
             (to (if (and (< end (length line)) (eq (aref line end) ?\s)) (1+ end) end)))
        (when-let* ((colour (roost--tint face)))
          (add-face-text-property from to (list :background colour) t line))
        (setq pos end)))
    (remove-text-properties 0 (length line) '(roost-tint nil) line)
    line))

(defvar roost--name-counts nil
  "While a list of tasks is drawn, how many tasks have each name in each project.
See `roost--count-names'.  Counted once for the list, not for each row.")

(defun roost--name-key (task)
  "TASK's host, project and name, which no other task's has unless it is a twin."
  (list (roost--field task 'host) (roost--field task 'repo) (roost--field task 'name)))

(defun roost--count-names ()
  "How many tasks have each name in each project, by `roost--name-key'."
  (let ((counts (make-hash-table :test 'equal)))
    (maphash (lambda (_ task) (cl-incf (gethash (roost--name-key task) counts 0))) roost--tasks)
    counts))

(defun roost--row-name (task &optional width face)
  "TASK's name in FACE for its row under its project, cut to WIDTH columns.
When another task in the project has the same name, the start of its ID
follows, dim, as in `roost-open-task' and tab names, and then a dim ±
when its changes are large (`roost-large-change').  Cutting the name to
fit keeps the ID, and the ± while a column of the name is left beside
them: a row that narrow keeps its room for its status."
  (let* ((name (roost--field task 'name))
         (id (roost--field task 'id))
         ;; TASK is one of them.
         (twin (> (gethash (roost--name-key task) (or roost--name-counts (roost--count-names)) 0) 1))
         (suffix (if (and twin id) (concat " " (substring id 0 (min 6 (length id)))) ""))
         (mark (roost--large-change-mark task))
         (suffix (if (and mark (or (not width) (> width (+ (length suffix) 2))))
                     (concat suffix " " mark)
                   suffix)))
    (concat (propertize (if width
                            (truncate-string-to-width name (max 1 (- width (length suffix)))
                                                      nil nil "…")
                          name)
                        'face face)
            (propertize suffix 'face 'roost-dim))))

(defun roost--dashboard-layout (tasks width)
  "Column widths for TASKS in a window WIDTH columns wide.
Rows started from another task indent only as far as the window leaves
room beside the name and the columns that always show.  The changes
column shrinks first, then the agent column is dropped."
  (let* ((plain (min 28 (max 8 (apply #'max (mapcar (lambda (task) (string-width (roost--row-name task)))
                                                    tasks)))))
         (agent (> (length (delete-dups (mapcar (lambda (task) (or (roost--field task 'agent) "claude"))
                                                tasks)))
                   1))
         (widest (min 40 (apply #'max (mapcar (lambda (task) (string-width (roost--changes task t)))
                                             tasks))))
         (changes widest)
         (pr (apply #'max (mapcar (lambda (task) (string-width (roost--pr-marker task))) tasks)))
         ;; Bullet, name, status, since and their separators.
         (base (+ 4 plain 2 11 1 6 2 (if (> pr 0) (+ pr 2) 0)))
         (indent (max 0 (min (apply #'max (mapcar (lambda (task) (length (roost--nesting-indent task))) tasks))
                             (- width base))))
         (name (apply #'max plain
                      (append
                       (mapcar (lambda (task)
                                 (+ (min indent (length (roost--nesting-indent task)))
                                    (min 28 (string-width (roost--row-name task)))))
                               tasks)
                       ;; An offer's title, a level further in, as far as
                       ;; the window leaves room.
                       (mapcan (lambda (task)
                                 (mapcar (lambda (offer)
                                           (min (+ plain (max 0 (- width base)))
                                                (+ (min (+ 2 indent) (+ 2 (length (roost--nesting-indent task))))
                                                   (min 28 (string-width (alist-get 'title offer))))))
                                         (roost--offers task)))
                               tasks))))
         (fixed (+ base (- name plain)))
         (over (- (+ fixed (if agent 10 0) (if (> changes 0) (+ changes 2) 0)) width)))
    (when (> over 0)
      (setq changes (max 0 (- changes over)))
      (when (and agent (< changes 12))
        (setq agent nil changes (min widest (max 0 (- width fixed 2))))))
    (when (< changes 6) (setq changes 0))
    (list :name name :indent indent :agent agent :changes changes :pr pr)))

(defun roost--dashboard-row (task layout width)
  "Dashboard line for TASK using column LAYOUT, fitting WIDTH columns."
  (let* ((status (roost--row-word task))
         (face (roost--status-word-face (roost--attention-status task)))
         (cell (lambda (text size &optional cell-face)
                 (propertize (truncate-string-to-width text size nil ?\s "…") 'face cell-face)))
         ;; Under the task it was started from.
         (indent (let ((nested (roost--nesting-indent task)))
                   (substring nested 0 (min (length nested) (or (plist-get layout :indent) 0)))))
         (name (concat indent (roost--row-name task (max 1 (- (plist-get layout :name) (length indent))))))
         (line (concat "  " (roost--status-light task 'dashboard) " "
                       name (make-string (max 0 (- (plist-get layout :name) (string-width name))) ?\s)
                       (roost--tint-marked
                        (concat "  "
                                (propertize (truncate-string-to-width status 11 nil nil "…")
                                            'face face
                                            'roost-tint (and (memq face '(roost-status-permission
                                                                          roost-status-failed))
                                                             face))
                                (make-string (max 0 (- 11 (string-width status))) ?\s)
                                " "))
                       (funcall cell (roost--elapsed (roost--field task 'updatedAt)) 6 'roost-dim) "  "
                       (if (> (plist-get layout :pr) 0)
                           (concat (truncate-string-to-width (roost--pr-marker task) (plist-get layout :pr)
                                                             nil ?\s "…")
                                   "  ")
                         "")
                       (if (plist-get layout :agent)
                           (concat (funcall cell (or (roost--field task 'agent) "claude") 8 'roost-dim) "  ")
                         "")
                       (if (> (plist-get layout :changes) 0)
                           (concat (roost--fontify-changes
                                    (truncate-string-to-width (roost--changes task t)
                                                              (plist-get layout :changes) nil ?\s "…"))
                                   "  ")
                         "")))
         (room (- width (string-width line) 1)))
    (concat line
            (when (> room 8)
              ;; In `roost-prose', which fits more in its room than the
              ;; columns do; it is cut short of three times as many, with
              ;; an ellipsis should that cut be the one that shows.
              (let ((text (truncate-string-to-width
                           (roost--one-line (roost--with-since-looked
                                             task (or (roost--permission-request task)
                                                      ;; While it works, what it is doing.
                                                      (roost--activity task)
                                                      (roost--last-message-summary task)
                                                      (roost--prompt-text task))))
                           (* 3 room) nil nil "…")))
                (roost--truncate-width (propertize text 'face '(roost-dim roost-prose)) room))))))

(defun roost--insert-unreachable-hosts (tasks width &optional brief)
  "Name each host Roost cannot reach that has none of TASKS to show.
Its tasks are unknown rather than absent, as after a restart while it is
down.  Each line fits within WIDTH, leaving the rest to hover; BRIEF
says only that the host is unreachable."
  (dolist (host (roost--hosts))
    (when-let* ((error (gethash host roost--errors))
                ((not (seq-some (lambda (task) (equal (roost--field task 'host) host)) tasks))))
      (insert (propertize (truncate-string-to-width
                           (if brief
                               (format "%s unreachable" (roost--host-label host))
                             (format "%s is unreachable, so its tasks are unknown: %s"
                                     (roost--host-label host) (roost--one-line error)))
                           width nil nil "…")
                          'face 'roost-status-failed
                          'help-echo (format "%s\nM-x roost-doctor checks this host" error))
              "\n"))))

(defun roost--insert-empty-dashboard ()
  "Explain how to start when there are no tasks."
  (insert (propertize "No tasks yet." 'face 'roost-title) "\n\n"
          (substitute-command-keys
           (concat
            "  \\<roost-dashboard-mode-map>\\[roost-new-task]  Start a task: choose a project (local, or remote over TRAMP), an agent, and a prompt.\n"
            "     Run \\<global-map>\\[roost-new-task] on an Org heading or with a region selected to start from it;\n"
            "     in the draft, \\<roost-compose-mode-map>\\[roost-compose-set-issue] picks an issue from GitHub, GitLab or Jira.\n"
            "  \\<roost-dashboard-mode-map>\\[roost-new-conversation]  Or talk first: an agent in no project, with nothing to write beforehand.\n"
            "     Ask it to plan a piece of work, and each task it offers waits here for you to start.\n"
            "  \\[roost-dispatch]  Every command.\n"
            "  \\[roost-doctor]  Check this machine and each host.\n"))
          (format "\n  Watching %s.\n"
                  (string-join (mapcar #'roost--host-label (roost--hosts)) ", "))))

(defun roost--render-dashboard ()
  "Render the dashboard from cached state, keeping point on the same row.
The mark stays where it was."
  ;; Before measuring: the lights' margin narrows the window.
  (roost--light-margins)
  (let* ((window (get-buffer-window (current-buffer) t))
         (position (if window (window-point window) (point)))
         (key (get-text-property position 'roost-task))
         (offer (get-text-property position 'roost-offer))
         (heading (unless (or key offer) (get-text-property position 'roost-directory)))
         (mark (roost--mark-place))
         (start-line (when window (line-number-at-pos (window-start window))))
         ;; Without fringes, as in a terminal, a full line would lose its last
         ;; column to the truncation mark; this leaves room for it.
         (width (roost--narrowest-width 120))
         (tasks (roost-tasks))
         (roost--name-counts (roost--count-names))
         (inhibit-read-only t))
    (erase-buffer)
    (roost--insert-unreachable-hosts tasks width)
    (if (null tasks)
        (roost--insert-empty-dashboard)
      (let ((layout (roost--dashboard-layout tasks width)))
        (insert (roost--summary tasks) "\n")
        (dolist (group (roost--task-groups tasks))
          (let ((host (caar group)) (repo (cadar group)) (start (1+ (point))))
            (let* ((heading (propertize (format "%s · %s" (roost--host-label host)
                                                (file-name-nondirectory (directory-file-name (or repo "?"))))
                                        'face 'roost-heading))
                   (note (if (gethash host roost--errors)
                             (propertize "  unreachable; showing the last known state" 'face 'roost-status-failed)
                           ""))
                   ;; A long path keeps its end, which names the project.
                   (room (- width (roost--text-width heading) (roost--text-width note) 2)))
              (insert roost--gap
                      (roost--ruled
                       (concat heading
                               (if (< room 4) ""
                                 (propertize (concat "  " (roost--truncate-start
                                                           (roost--abbreviate-path (or repo "") host) room))
                                             'face 'roost-dim))
                               note "\n"))))
            ;; `c' on the heading starts a task in this project.
            (when repo
              (put-text-property start (point) 'roost-directory
                                 (roost--project-directory (cadr group))))
            (dolist (task (cdr group))
              (let ((row (list 'roost-task (roost--key task) 'keymap roost--dashboard-row-map)))
                (insert (apply #'propertize (roost--dashboard-row task layout width)
                               'mouse-face 'highlight
                               'help-echo (concat (roost--large-change-echo task)
                                                  "mouse-1: open · mouse-3: actions")
                               row)
                        ;; Without `mouse-face', so each row lights up alone,
                        ;; but still the task's, for point and clicks there.
                        (apply #'propertize "\n" row)))
              (dolist (offer (roost--offers task))
                (roost--insert-offer-row task offer (roost--dashboard-offer-row task offer layout width))))))))
    (let ((target (or (and key (roost--task-row key))
                      ;; One no longer waiting leaves you on its task.
                      (and offer (or (roost--offer-row offer) (roost--task-row (car offer))))
                      (and heading (roost--heading-row heading))
                      (text-property-not-all (point-min) (point-max) 'roost-task nil)
                      (point-min))))
      (goto-char target)
      (roost--restore-mark mark)
      (when window
        (set-window-start window (save-excursion (goto-char (point-min))
                                                 (forward-line (1- start-line))
                                                 (point)))
        (set-window-point window target)))
    (roost--lights-forget 'dashboard (mapcar #'roost--key tasks))))

(defun roost--dashboard-task ()
  "The task on the current dashboard line, if any: on an offer's, the one
whose agent made it, which its row sits under."
  (when-let* ((start (line-beginning-position))
              (key (or (get-text-property start 'roost-task)
                       (car (get-text-property start 'roost-offer)))))
    (gethash key roost--tasks)))

(defun roost-dashboard-next-task (&optional count)
  "Move to the next task line, or COUNT lines of tasks.
An offer listed under its task's line counts as one."
  (interactive "p")
  (dotimes (_ (abs (or count 1)))
    (let ((step (if (< (or count 1) 0) -1 1)) (origin (point))
          (row (lambda () (or (get-text-property (point) 'roost-task) (get-text-property (point) 'roost-offer)))))
      (forward-line step)
      (while (and (not (funcall row))
                  (zerop (forward-line step))))
      (unless (funcall row) (goto-char origin)))))

(defun roost-dashboard-previous-task (&optional count)
  "Move to the previous task line, or COUNT lines of tasks."
  (interactive "p")
  (roost-dashboard-next-task (- (or count 1))))

(defun roost-dashboard-mouse-open (event)
  "Open the task clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  ;; Never ask which task: a click that fell through to that question
  ;; left it open, unseen, and held every later open behind it.  The
  ;; row clicked says which, whatever buffer is current.
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (key (and (windowp window) (window-live-p window) (posn-point posn)
                   (with-current-buffer (window-buffer window)
                     (get-text-property (posn-point posn) 'roost-task)))))
    (roost-open-task (or (and key (gethash key roost--tasks))
                         (user-error "That task is no longer listed; refresh with `g'"))
                     t)))

(defun roost-dashboard-mouse-menu (event)
  "Show the actions for the task clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (popup-menu roost-task-menu event))

(defun roost-sidebar-new-task (&optional event)
  "Draft a task in the project at point in the sidebar, or clicked in EVENT."
  (interactive (list last-nonmenu-event))
  (when (mouse-event-p event)
    (mouse-set-point event))
  (let* ((project (or (get-text-property (point) 'roost-project) (user-error "No project here")))
         (start (lambda ()
                  (if (stringp project)
                      (roost--compose nil nil project)
                    ;; Chosen by menus after a click, and locally in the
                    ;; system's folder dialog, as `read-directory-name'
                    ;; shows one then.
                    (when-let* ((directory (roost--read-project-directory)))
                      (roost--compose nil nil (file-name-as-directory (expand-file-name directory))))))))
    ;; A question left open would hold up the folder's, or the new task.
    (or (roost--quit-questions-left-open start)
        (funcall start))))

(easy-menu-define roost-project-menu nil
  "Menu for a project the sidebar lists for a new task."
  '("Project"
    ["New task here" roost-sidebar-new-task]
    ["Forget" roost-forget-project :active (stringp (get-text-property (point) 'roost-project))]))

(defun roost-sidebar-project-menu (event)
  "Show what can be done with the project clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (popup-menu roost-project-menu event))

(defvar roost--shown-mode-line-count nil
  "The waiting count the mode lines last showed.")

;; Defined with searching, below.
(defvar roost--search-buffer)

(defun roost--redraw ()
  "Refresh an existing dashboard and task panels without changing focus."
  (roost--note-watched-agent)
  ;; Before the sidebar is drawn, so that it marks a task taken up.
  (dolist (frame (frame-list))
    (unless (frame-parent frame)
      (with-selected-frame frame (roost--adopt-shown-task))))
  ;; Mode lines are redrawn with their windows, so a terminal you are not
  ;; typing in would keep showing an old count.
  (let ((count (roost--mode-line-count t)))
    (unless (equal count roost--shown-mode-line-count)
      (setq roost--shown-mode-line-count count)
      (force-mode-line-update t)))
  (roost--mode-line-light-check)
  (when-let* ((buffer (get-buffer "*roost*")))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-dashboard-mode)
        (roost--render-visible #'roost--render-dashboard))))
  (when-let* ((buffer (get-buffer roost--sidebar-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-sidebar-list-mode)
        (roost--render-visible #'roost--render-sidebar))))
  ;; Search results show their live tasks as they are now.
  (when-let* ((buffer (get-buffer roost--search-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-search-mode)
        (roost--render-visible #'roost--render-search))))
  ;; Data that just arrived can name the task a restored workspace shows,
  ;; in any frame.
  (when (memq #'roost--layout-changed (default-value 'window-configuration-change-hook))
    (roost--sync-all-frames))
  (roost--compose-redraw-changing)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (cond ((derived-mode-p 'roost-task-info-mode)
             (roost--render-visible #'roost--render-task-info))
            ;; Attempts compared show each as it is now.
            ((derived-mode-p 'roost-attempts-mode)
             (roost--render-visible #'roost--render-attempts))))))

;;;###autoload
(defun roost-dashboard ()
  "Open the dashboard and watch configured and remembered hosts."
  (interactive)
  (let ((buffer (get-buffer-create "*roost*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-dashboard-mode) (roost-dashboard-mode)))
    ;; In the window you are in, like the task draft; q gives it back.
    (roost--leave-side-window)
    (roost--pop-to-buffer-in-place buffer)
    (roost--redraw))
  (roost-watch-mode 1)
  (roost-refresh))

;;;; Several attempts at one prompt

;; A draft can make several tasks from its prompt (see
;; `roost-compose-set-attempts').  Each is a task like any other, whose
;; host records which attempt it is.  What Roost adds is a way to see what
;; each changed, file by file, and to compare two of them in Ediff: you
;; merge one, and finish the others yourself.

(defun roost--attempt (task)
  "What TASK's host records of it as one of several attempts at a prompt, or nil.
An alist: `group', which the attempts of one draft share, `n', which of
them this is, from 1, and `of', how many the draft asked for."
  (let ((attempt (roost--field task 'attempt)))
    (and (consp attempt)
         (stringp (alist-get 'group attempt))
         (integerp (alist-get 'n attempt))
         (integerp (alist-get 'of attempt))
         attempt)))

(defun roost--attempts-in-order (tasks)
  "TASKS, each an attempt, by which attempt each is."
  (sort tasks (lambda (a b) (< (alist-get 'n (roost--attempt a)) (alist-get 'n (roost--attempt b))))))

(defun roost--attempt-group (host group)
  "The attempts of GROUP that Roost has on HOST, in their order."
  (roost--attempts-in-order
   (seq-filter (lambda (task)
                 (and (equal (roost--field task 'host) host)
                      (equal (alist-get 'group (roost--attempt task)) group)))
               (hash-table-values roost--tasks))))

(defun roost--attempts (task)
  "The other attempts at the prompt TASK was made from, in their order.
Those Roost has still: the tasks one draft made with TASK, on its host."
  (when-let* ((attempt (roost--attempt task)))
    (let ((key (roost--key task)))
      (seq-remove (lambda (other) (equal (roost--key other) key))
                  (roost--attempt-group (roost--field task 'host) (alist-get 'group attempt))))))

(defun roost--attempts-together (tasks)
  "TASKS in order, with the attempts at one prompt together, in their own order.
They go where the first of them is: their host starts them at the same
time, so in any order, and another task may start among them."
  (if (not (seq-some #'roost--attempt tasks))
      tasks
    (let ((groups (make-hash-table :test 'equal))
          ordered)
      (dolist (task tasks)
        (when-let* ((attempt (roost--attempt task)))
          (push task (gethash (alist-get 'group attempt) groups))))
      (dolist (task tasks)
        (if-let* ((attempt (roost--attempt task)))
            (when-let* ((group (gethash (alist-get 'group attempt) groups)))
              (remhash (alist-get 'group attempt) groups)
              (setq ordered (nconc (nreverse (roost--attempts-in-order group)) ordered)))
          (push task ordered)))
      (nreverse ordered))))

(defun roost--names (names)
  "NAMES joined for a sentence, as \"a, b and c\"."
  (if (cdr names)
      (concat (string-join (butlast names) ", ") " and " (car (last names)))
    (car names)))

(defun roost--attempt-detail (task)
  "Which attempt at its prompt TASK is, and the others Roost has, as words.
Nil for a task that is no attempt."
  (when-let* ((attempt (roost--attempt task)))
    (let ((which (format "%d of %d" (alist-get 'n attempt) (alist-get 'of attempt)))
          (others (roost--attempts task)))
      (if others
          (format "%s, beside %s · %s compares them" which
                  (string-join (mapcar (lambda (other) (roost--field other 'name)) others) ", ")
                  (propertize "=" 'face 'roost-key))
        (concat which "; the others are finished")))))

(defun roost--attempt-label (task)
  "TASK, an attempt, as a choice among the attempts at its prompt."
  (format "%d %s" (alist-get 'n (roost--attempt task)) (roost--field task 'name)))

(defun roost--attempt-file (task path)
  "The entry of TASK's changed files for PATH, or nil if TASK leaves it alone."
  (seq-find (lambda (file) (equal (alist-get 'path file) path)) (roost--field task 'files)))

(defvar-local roost--attempts-shown nil
  "The attempts this buffer compares, as (HOST GROUP).")

(defun roost--attempts-of (shown)
  "The attempts Roost has of those SHOWN, as `roost--attempts-shown' names them."
  (when shown
    (roost--attempt-group (car shown) (cadr shown))))

(defvar-keymap roost-attempts-mode-map
  :doc "Keys where the attempts at one prompt are compared."
  "RET" #'roost-attempts-visit
  "m" #'roost-attempts-merge
  "g" #'roost-attempts-refresh
  "h" #'roost-dispatch
  "?" #'roost-dispatch)

(define-derived-mode roost-attempts-mode special-mode "Roost Attempts"
  "The attempts at one prompt, and what each changed, file by file.
On an attempt's line, task commands such as those in
\\[roost-dispatch] act on that attempt.
\\{roost-attempts-mode-map}"
  (when roost-decorate (setq-local line-spacing roost--line-spacing))
  (setq-local truncate-lines t)
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-attempts-mode roost-evil-state)
  (roost--quiet-display))

(defun roost--attempts-buffer (host group)
  "The buffer that compares the attempts of GROUP on HOST, made if there is none.
Named for the first of them Roost has."
  (let ((shown (list host group)))
    (or (seq-find (lambda (buffer) (equal (buffer-local-value 'roost--attempts-shown buffer) shown))
                  (buffer-list))
        (with-current-buffer (generate-new-buffer
                              (format "*roost attempts: %s*"
                                      (roost--field (car (roost--attempt-group host group)) 'name)))
          (roost-attempts-mode)
          (setq roost--attempts-shown shown)
          (current-buffer)))))

(defun roost--attempt-cell (file)
  "What an attempt did to a file, for its column: FILE is its entry, or nil."
  (cond ((null file) (propertize "·" 'face 'roost-dim))
        ((alist-get 'untracked file) (propertize "new" 'face 'roost-diff-added))
        ((alist-get 'added file)
         (roost--fontify-changes (format "+%d −%d" (alist-get 'added file) (or (alist-get 'deleted file) 0))))
        (t (propertize "binary" 'face 'roost-dim))))

(defun roost--insert-attempt-rows (attempts)
  "Insert a line for each of ATTEMPTS: its number, name, status and changes.
And its agent, where they are by more than one.  The name opens the
attempt, and the line is its task's, as a dashboard row is."
  (let* ((names (apply #'max (mapcar (lambda (task) (string-width (roost--field task 'name))) attempts)))
         (words (apply #'max (mapcar (lambda (task) (string-width (roost--row-word task))) attempts)))
         (agents (delete-dups (mapcar (lambda (task) (or (roost--field task 'agent) "claude")) attempts)))
         (agent-width (apply #'max (mapcar #'string-width agents))))
    (dolist (task attempts)
      (let ((start (point))
            (key (roost--key task))
            (name (roost--field task 'name))
            (word (roost--row-word task))
            (changes (roost--changes task)))
        (insert (format "  %d  " (alist-get 'n (roost--attempt task))))
        (insert-text-button name 'follow-link t 'face 'roost-field
                            'help-echo "mouse-1 or RET: open it"
                            'action (lambda (_) (roost--attempts-open key)))
        (insert (make-string (- names (string-width name)) ?\s) "  "
                ;; Whose attempt it is, where they are by more than one agent.
                (if (cdr agents)
                    (concat (propertize (truncate-string-to-width (or (roost--field task 'agent) "claude")
                                                                  agent-width nil ?\s)
                                        'face 'roost-dim)
                            "  ")
                  "")
                (propertize word 'face (roost--status-word-face (roost--attention-status task)))
                (make-string (- words (string-width word)) ?\s) "  "
                (cond ((not (assq 'diff task)) (propertize "Refreshing…" 'face 'roost-dim))
                      ((string-empty-p changes) (propertize "No changes yet" 'face 'roost-dim))
                      (t (roost--fontify-changes changes)))
                "\n")
        (put-text-property start (point) 'roost-task key)))))

(defconst roost--attempt-path-width 48
  "The most columns a file's path takes where attempts are compared.")

(defun roost--insert-attempt-files (attempts shown)
  "Insert a line for each file any of ATTEMPTS changed, with a column for each.
A column says what its attempt did to the file, or that it left it
alone.  The path compares the file between the attempts SHOWN, as
`roost--attempts-shown' has them."
  (let* ((paths (sort (seq-uniq (seq-mapcat (lambda (task)
                                              (mapcar (lambda (file) (alist-get 'path file))
                                                      (roost--field task 'files)))
                                            attempts))
                      #'string<))
         (rows (mapcar (lambda (path)
                         (cons path (mapcar (lambda (task) (roost--attempt-cell (roost--attempt-file task path)))
                                            attempts)))
                       paths))
         (path-width (min roost--attempt-path-width
                          (apply #'max 4 (mapcar #'string-width paths))))
         (widths (seq-map-indexed
                  (lambda (_ index)
                    (apply #'max 6 (mapcar (lambda (row) (string-width (nth index (cdr row)))) rows)))
                  attempts)))
    (if (null paths)
        (insert "\n" (propertize "None of them has changed a file yet.\n" 'face 'roost-dim))
      ;; Each column under its attempt's number.
      (insert "\n")
      (let ((start (point)))
        (insert (make-string (+ 2 path-width) ?\s))
        (cl-mapc (lambda (task width)
                   (insert "  " (propertize (string-pad (number-to-string (alist-get 'n (roost--attempt task)))
                                                        width nil t)
                                            'face 'roost-dim)))
                 attempts widths)
        (insert "\n")
        ;; Ruled off from the files under it, as a table's heading is.
        (when-let* ((colour (roost--hairline)))
          (add-face-text-property start (point)
                                  (list :underline (list :color colour :position t) :extend t) t)))
      (pcase-dolist (`(,path . ,cells) rows)
        (let ((start (point))
              (label (if (> (string-width path) path-width)
                         ;; A long path keeps its end, which names the file.
                         (concat "…" (truncate-string-to-width
                                      path (string-width path) (- (string-width path) (1- path-width))))
                       path)))
          (insert "  ")
          (insert-text-button label 'follow-link t 'face 'roost-field
                              'help-echo (concat path "\nmouse-1 or RET: compare the attempts that changed it")
                              'action (lambda (_)
                                        ;; As for a command you give: a question
                                        ;; you left open would hold it back.
                                        (roost--quit-questions-left-open
                                         (lambda () (roost--attempts-compare shown path)))
                                        (roost--attempts-compare shown path)))
          (insert (make-string (- path-width (string-width label)) ?\s))
          (cl-mapc (lambda (cell width)
                     (insert "  " (make-string (- width (string-width cell)) ?\s) cell))
                   cells widths)
          (insert "\n")
          (put-text-property start (point) 'roost-attempts-file path))))))

(defun roost--render-attempts ()
  "Redraw the attempts the current buffer compares, as Roost has them now.
Windows showing them keep their place."
  (let* ((inhibit-read-only t)
         (shown roost--attempts-shown)
         (attempts (roost--attempts-of shown))
         (line (line-number-at-pos))
         (column (current-column))
         (places (roost--window-places)))
    (erase-buffer)
    (insert (propertize "Attempts at one prompt" 'face 'roost-title) "\n")
    (if (null attempts)
        (insert "\nNone of these attempts is left.\n")
      (let* ((task (car attempts))
             (prompt (roost--prompt-text task)))
        (insert (roost--ruled
                 (concat (propertize (concat (roost--host-label (roost--field task 'host)) " · "
                                             (roost--project-name task)
                                             (when prompt
                                               (concat " · " (truncate-string-to-width (roost--one-line prompt)
                                                                                       60 nil nil "…"))))
                                     'face 'roost-dim)
                         "\n"))
                "\n"))
      (roost--insert-attempt-rows attempts)
      (roost--insert-attempt-files attempts shown)
      (insert "\n"
              (roost--quiet-but-keys
               (substitute-command-keys
                (concat "\\<roost-attempts-mode-map>\\[roost-attempts-visit] on a file compares it between two attempts in Ediff,"
                        " or opens it in the one that changed it.\n"
                        "\\[roost-attempts-merge] merges an attempt and retires it; the others stay until you finish them."
                        "  \\[roost-attempts-refresh] refreshes.")))
              "\n"))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (roost--restore-window-places places)))

(defun roost--attempts-open (key)
  "Open the attempt with KEY, as `roost-open-task' does, if Roost has it still."
  (roost-open-task (or (gethash key roost--tasks)
                       (user-error "This attempt has been retired or is unavailable"))))

(defun roost--attempts-compare (shown path)
  "Compare the file at PATH between the attempts SHOWN that changed it.
SHOWN is as `roost--attempts-shown' has them.  Two that changed it are
compared in Ediff, each worktree's copy beside the other's; of more,
the two you choose.  A file only one changed is visited there."
  (let* ((changed (seq-filter (lambda (task) (roost--attempt-file task path))
                              (roost--attempts-of shown)))
         (copy (lambda (task) (roost--worktree-file path (roost--remote-directory task))))
         (pair (if (not (cddr changed))
                   changed
                 (let* ((choices (mapcar (lambda (task) (cons (roost--attempt-label task) task)) changed))
                        (one (roost--choose-from (format "Compare %s in attempt: " path) choices))
                        (other (and one (roost--choose-from
                                         (format "Compare it in %s with attempt: " (roost--field one 'name))
                                         (rassq-delete-all one (copy-sequence choices))))))
                   (and other (list one other))))))
    (cond ((null changed)
           (user-error "No attempt changes %s now" path))
          ((cdr pair)
           (ediff-files (funcall copy (car pair)) (funcall copy (cadr pair))))
          ;; Not when you chose none of several.
          (pair
           (find-file (funcall copy (car pair)))))))

(defun roost-attempts-visit ()
  "Compare the file at point between the attempts that changed it.
Two attempts' copies of it open in Ediff: the two that changed it, or of
more, the two you choose.  A file only one attempt changed is visited in
that attempt's worktree.  On an attempt's line, open the attempt, as
\\<roost-dashboard-mode-map>\\[roost-open-task] does in the dashboard."
  (interactive)
  (let ((path (get-text-property (line-beginning-position) 'roost-attempts-file))
        (key (get-text-property (line-beginning-position) 'roost-task))
        (shown roost--attempts-shown))
    (unless (or path key)
      (user-error "Move to a file to compare it, or to an attempt to open it"))
    ;; A question you left open would take the one this asks.
    (roost--quit-questions-here #'roost-attempts-visit)
    (if path
        (roost--attempts-compare shown path)
      (roost--attempts-open key))))

(defun roost-attempts-merge ()
  "Merge the attempt at point into its branch and retire it.
As `roost-merge-retire' does, which asks first.  Off an attempt's line,
ask which attempt.  The others stay as they are: Roost deletes work only
when you discard a task, so finish each yourself, as with
\\<roost-dashboard-mode-map>\\[roost-retire] on it."
  (interactive)
  (let ((attempts (roost--attempts-of roost--attempts-shown)))
    (unless attempts
      (user-error "None of these attempts is left"))
    (when-let* ((task (or (roost--dashboard-task)
                          (roost--choose-from "Merge attempt: "
                                              (mapcar (lambda (task) (cons (roost--attempt-label task) task))
                                                      attempts)))))
      (roost-merge-retire task))))

(defun roost-attempts-refresh ()
  "Redraw the attempts, and ask their host for each one's changes as they are now."
  (interactive)
  (roost--render-attempts)
  (when (roost--attempts-of roost--attempts-shown)
    (roost--refresh-host (car roost--attempts-shown) nil)))

;;;###autoload
(defun roost-compare-attempts (&optional task)
  "Compare TASK with the other attempts at its prompt, file by file.
A draft makes several attempts when you ask it to, with
\\<roost-compose-mode-map>\\[roost-compose-set-attempts] there: tasks from one prompt, by one agent or several.  This
lists each attempt with its status and changes, then every file any of
them changed, with a column for each attempt that says what it did to
the file.  \\<roost-attempts-mode-map>\\[roost-attempts-visit] on a file compares two attempts' copies of it in Ediff,
and \\[roost-attempts-merge] merges an attempt and retires it.  The others stay until you
finish them."
  (interactive)
  (setq task (roost--choose task))
  (let ((name (roost--field task 'name)))
    (cond ((not (roost--attempt task))
           (user-error "%s is the only attempt at its prompt; %s in the draft of a new task makes several"
                       name (substitute-command-keys
                             "\\<roost-compose-mode-map>\\[roost-compose-set-attempts]")))
          ((not (roost--attempts task))
           (user-error "%s is the only attempt left" name))))
  (let ((buffer (roost--attempts-buffer (roost--field task 'host)
                                        (alist-get 'group (roost--attempt task))))
        (key (roost--key task)))
    (with-current-buffer buffer
      (roost--render-attempts))
    ;; In the window you are in, like the dashboard; q gives it back.
    (roost--leave-side-window)
    (roost--pop-to-buffer-in-place buffer)
    ;; On the attempt you came from.
    (when-let* ((row (roost--task-row key)))
      (goto-char row))))

;;;; Searching conversations

(defvar roost-search-history nil
  "Queries given to `roost-search'.")

(defconst roost--search-buffer "*roost search*"
  "Name of the buffer that shows search results.")

(defvar-local roost--search-query nil
  "The query this buffer shows results for.")
(defvar-local roost--search-replies nil
  "Each host's reply so far: (HOST . RESULT), or (HOST :error MESSAGE).")
(defvar-local roost--search-generation 0
  "Counts searches in this buffer, so that replies to an older one are ignored.")
(defvar-local roost--search-expanded nil
  "Identities of the results whose whole message is shown.")
(defvar-local roost--search-baseline nil
  "For each host that replied: (HOST . task lists asked of it by then).")
(defvar-local roost--search-hosts nil
  "The hosts this search asked.")

(defvar-keymap roost-search-mode-map
  :doc "Keys in Roost's search results."
  "RET" #'roost-search-open
  "TAB" #'roost-search-toggle
  "n" #'roost-search-next
  "p" #'roost-search-previous
  "g" #'roost-search-again
  "/" #'roost-search
  "h" #'roost-dispatch
  "?" #'roost-dispatch)

(define-derived-mode roost-search-mode special-mode "Roost Search"
  "Messages in your tasks' conversations that match a search.
On a live task's message, task commands such as those in
\\[roost-dispatch] act on that task.
\\{roost-search-mode-map}"
  (setq-local truncate-lines t
              revert-buffer-function (lambda (&rest _) (roost-search-again)))
  (add-hook 'window-size-change-functions #'roost--search-resized nil t)
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-search-mode roost-evil-state)
  (roost--quiet-display))

(defun roost--search-resized (window)
  "Fit the results to WINDOW again after it is resized."
  (with-current-buffer (window-buffer window)
    (roost--render-search)))

;;;###autoload
(defun roost-search (query)
  "Show the messages in your tasks' conversations that contain QUERY.
Every word of QUERY must be in one message, written by you or by the
agent; tool output is not searched.  Each host searches the Claude Code
conversations of its tasks, including tasks since retired, whose
conversations Claude keeps, newest first and for at most 20 seconds.
RET on a live task's message opens it; TAB shows more of a message,
up to its first 1,500 characters."
  (interactive (list (read-string "Search conversations: " nil 'roost-search-history)))
  (when (string-blank-p query)
    (user-error "Search for at least one word"))
  (let ((buffer (get-buffer-create roost--search-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-search-mode) (roost-search-mode))
      (setq roost--search-query (string-trim query)
            roost--search-expanded nil))
    (roost--search-start buffer)
    ;; In the window you are in, like the dashboard; q gives it back.
    (roost--leave-side-window)
    (roost--pop-to-buffer-in-place buffer)))

(defun roost-search-again ()
  "Search every host again for this buffer's query."
  (interactive)
  (roost--search-start (current-buffer)))

(defun roost--search-start (buffer)
  "Ask every host for BUFFER's query, and show the replies as they come."
  (with-current-buffer buffer
    (let ((generation (cl-incf roost--search-generation))
          (query roost--search-query))
      (setq roost--search-replies nil
            roost--search-baseline nil
            roost--search-hosts (roost--hosts))
      (dolist (host roost--search-hosts)
        (roost--request host "search" (list (cons 'query query))
                        (lambda (result) (roost--search-arrived buffer generation host result))
                        (lambda (err) (roost--search-arrived buffer generation host (list :error err)))))
      (roost--render-search))))

(defun roost--search-arrived (buffer generation host reply)
  "Show HOST's REPLY in BUFFER, unless it answers a search before GENERATION."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation roost--search-generation)
        (push (cons host reply) roost--search-replies)
        (unless (eq (car-safe reply) :error)
          (setf (alist-get host roost--search-baseline nil nil #'equal) (gethash host roost--list-requests 0)))
        (roost--render-search)
        ;; A result with an ID is a task the host still has; one Roost has
        ;; not fetched, as before it first watches, is fetched now, after
        ;; any list already on its way, and the redraw that follows shows it.
        (when-let* ((missing (seq-keep (lambda (result)
                                         (when-let* ((id (alist-get 'id result)))
                                           (unless (gethash (list host id) roost--tasks) id)))
                                       (and (not (eq (car-safe reply) :error)) (alist-get 'tasks reply)))))
          (roost--refresh-host host nil missing))))))

(defun roost--search-gone-p (host)
  "Whether Roost holds a task list asked of HOST after it replied to the search.
A live task such a list lacks has since been retired; one asked before
may predate the task."
  (when-let* ((replied (assoc host roost--search-baseline)))
    (> (gethash host roost--snapshots 0) (cdr replied))))

(defun roost--search-highlight (string words)
  "STRING with each of WORDS in it highlighted where a word starts, ignoring case.
Hosts match words so: \"test\" finds \"tests\", but not \"latest\"."
  (let ((string (copy-sequence string))
        (case-fold-search t))
    (dolist (word words string)
      (let ((regexp (concat (if (string-match-p "\\`[[:alnum:]_]" word) "\\(?:\\`\\|[^[:alnum:]_]\\)" "")
                            "\\(" (regexp-quote word) "\\)"))
            (start 0))
        (while (string-match regexp string start)
          (add-face-text-property (match-beginning 1) (match-end 1) 'roost-search-match nil string)
          (setq start (match-end 1)))))))

(defun roost--search-wrap (text width)
  "TEXT with each line wider than WIDTH columns broken between words.
Its prose is in `roost-prose', and widths are as shown.  A word wider
than WIDTH, such as a URL, is broken within, as in `roost--reply-preview'."
  (string-join (roost--wrap-width (roost--prose text) width) "\n"))

(defun roost--search-time (timestamp)
  "TIMESTAMP as a local date and time, or blanks if it is unreadable."
  (or (ignore-errors (format-time-string "%Y-%m-%d %H:%M" (date-to-time timestamp)))
      (make-string 16 ?\s)))

(defun roost--render-search ()
  "Draw the current search buffer from the replies received so far."
  (let* ((inhibit-read-only t)
         (place (get-text-property (line-beginning-position) 'roost-search-id))
         (places (roost--window-places))
         (mark (roost--mark-place))
         (words (split-string (downcase roost--search-query)))
         (pending (seq-remove (lambda (host) (assoc host roost--search-replies)) roost--search-hosts))
         (groups nil)
         (more 0)
         ;; Lines stay unwrapped, so each message is one line; a whole
         ;; message is wrapped to the window, inside its indentation.
         ;; Fitted to the narrowest window showing them, as a task's panel is.
         (columns (roost--narrowest-width 80))
         ;; Within the body's indentation of 6 columns, and 2 more.
         (width (max 1 (- columns 8))))
    (pcase-dolist (`(,host . ,reply) roost--search-replies)
      (unless (eq (car-safe reply) :error)
        (setq more (+ more (or (alist-get 'moreTasks reply) 0)))
        (dolist (result (alist-get 'tasks reply))
          (push (cons host result) groups))))
    (setq groups (sort groups (lambda (a b)
                                (string> (or (alist-get 'at (car (last (alist-get 'hits (cdr a))))) "")
                                         (or (alist-get 'at (car (last (alist-get 'hits (cdr b))))) "")))))
    (erase-buffer)
    (insert (roost--ruled (concat (propertize "Messages containing " 'face 'roost-dim)
                                  (propertize roost--search-query 'face 'roost-heading) "\n")))
    (when pending
      (insert (propertize (format "Searching %s…\n" (mapconcat #'roost--host-label pending ", "))
                          'face 'roost-dim)))
    (pcase-dolist (`(,host . ,reply) (reverse roost--search-replies))
      (cond ((eq (car-safe reply) :error)
             (insert (roost--banded (propertize (format "Could not search %s: %s\n" (roost--host-label host)
                                                        (cadr reply))
                                                'face 'roost-status-failed)
                                    'roost-status-failed)))
            ;; A host searches its newest conversations first, for so long.
            ((alist-get 'incomplete reply)
             (insert (propertize (format "%s ran out of time; it searched its newest conversations only\n"
                                         (roost--host-label host))
                                 'face 'roost-dim)))))
    ;; A host that failed was not searched, so say nothing of it.
    (let ((searched (mapcar #'car (seq-remove (lambda (reply) (eq (car-safe (cdr reply)) :error))
                                              (reverse roost--search-replies)))))
      (when (and (not groups) (not pending) searched)
        (insert (if (= (length searched) (length roost--search-replies))
                    "\nNo message in your tasks' conversations contains every word.\n"
                  (format "\nNo message in your tasks' conversations on %s contains every word.\n"
                          (mapconcat #'roost--host-label searched ", "))))))
    (pcase-dolist (`(,host . ,result) groups)
      (let* ((key (when-let* ((id (alist-get 'id result))) (list host id)))
             (task (and key (gethash key roost--tasks)))
             (key (unless (and key (not task) (roost--search-gone-p host)) key))
             (status (cond (task (roost--row-word task)) ((not key) "past task")))
             (row (and key (list 'roost-task key)))
             (start (point)))
        (insert "\n" (propertize (or (alist-get 'name result) "?") 'face 'roost-heading) "  "
                ;; A task retired before hosts recorded its repository has none.
                (propertize (if-let* ((repo (alist-get 'repo result)))
                                (format "%s · %s" (roost--host-label host)
                                        (file-name-nondirectory (directory-file-name repo)))
                              (roost--host-label host))
                            'face 'roost-dim)
                (if status
                    (concat "  " (propertize status 'face (if task
                                                               (roost--status-word-face (roost--attention-status task))
                                                             'roost-dim)))
                  "")
                "\n")
        (add-text-properties start (point) row)
        (when (> (or (alist-get 'more result) 0) 0)
          (insert (apply #'propertize
                         (format "  %d earlier messages match too\n" (alist-get 'more result))
                         'face 'roost-dim row)))
        (dolist (hit (alist-get 'hits result))
          (let* ((id (list host (or (alist-get 'id result) (alist-get 'key result))
                           (alist-get 'session hit) (alist-get 'line hit)))
                 (properties (append (list 'roost-search-id id 'roost-search-hit (list host result hit)) row))
                 (who (if (equal (alist-get 'role hit) "user") "You" "Claude")))
            (let* ((line (concat "  " (roost--search-time (alist-get 'at hit)) "  "
                                 (format "%-7s" who)
                                 (roost--search-highlight
                                  (roost--prose (or (alist-get 'snippet hit) "")) words)))
                   ;; Cut to the window, as the dashboard cuts replies: TAB
                   ;; shows the rest.
                   (shown (roost--truncate-width line columns)))
              (insert (apply #'propertize (concat shown "\n")
                             'roost-search-line t
                             'roost-search-cut (not (equal shown line))
                             properties))
              ;; Its line shows it whole now, as in a window since widened:
              ;; shown again below, it would only repeat.
              (when (and (equal shown line)
                         (equal (alist-get 'text hit) (alist-get 'snippet hit)))
                (setq roost--search-expanded (delete id roost--search-expanded))))
            (when (member id roost--search-expanded)
              (let ((body-start (point)))
                (insert (roost--search-highlight (roost--search-wrap (or (alist-get 'text hit) "") width)
                                                 words)
                        "\n")
                (add-text-properties body-start (point) properties)
                (put-text-property body-start (point) 'line-prefix "      ")
                (put-text-property body-start (point) 'wrap-prefix "      ")
                (put-text-property body-start (point) 'roost-search-body t)))))))
    (when (> more 0)
      (insert (propertize (format "\n%d more tasks match; add a word to narrow the search.\n" more)
                          'face 'roost-dim)))
    ;; Windows keep their scroll, and the mark stays; point stays on its message.
    (roost--restore-window-places places)
    (roost--restore-mark mark)
    (goto-char (point-min))
    (if-let* ((found (and place (roost--search-find place))))
        (goto-char found)
      (when-let* ((first (text-property-not-all (point-min) (point-max) 'roost-search-line nil)))
        (goto-char first)))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (set-window-point window (point)))))

(defun roost--search-find (id)
  "Where the message with ID starts, or nil.
IDs are lists made afresh by each redraw, so compare them with `equal'."
  (let ((position (point-min)) found)
    (while (and position (not found))
      (if (equal (get-text-property position 'roost-search-id) id)
          (setq found position)
        (setq position (next-single-property-change position 'roost-search-id))))
    found))

(defun roost--search-hit ()
  "The result on this line: (HOST RESULT HIT), or nil."
  (get-text-property (point) 'roost-search-hit))

(defun roost--search-whole-p ()
  "Whether the message on this line shows whole on it, folded.
Then showing more of it would only repeat it."
  (when-let* ((hit (nth 2 (roost--search-hit))))
    (and (not (member (get-text-property (point) 'roost-search-id) roost--search-expanded))
         (equal (alist-get 'text hit) (alist-get 'snippet hit))
         (not (get-text-property (line-beginning-position) 'roost-search-cut)))))

(defun roost-search-open ()
  "Open the live task of the message on this line, or show more of the message."
  (interactive)
  (let ((key (get-text-property (line-beginning-position) 'roost-task)))
    (cond ((and key (gethash key roost--tasks))
           (roost-open-task (gethash key roost--tasks) t))
          (key
           (roost--refresh-host (car key) nil (cdr key))
           (user-error "Roost is still fetching the tasks on %s; try again in a moment"
                       (roost--host-label (car key))))
          ((roost--search-whole-p)
           (user-error "Nothing to open: %s is no longer a task, and this is the whole message"
                       (alist-get 'name (nth 1 (roost--search-hit)))))
          ((roost--search-hit) (roost-search-toggle))
          (t (user-error "Put point on a message")))))

(defun roost-search-toggle ()
  "Show or hide more of the message on this line.
Hosts send a message's first 1,500 characters."
  (interactive)
  (let ((id (or (get-text-property (point) 'roost-search-id)
                (user-error "Put point on a message"))))
    (when (roost--search-whole-p)
      (user-error "This is the whole message"))
    (setq roost--search-expanded (if (member id roost--search-expanded)
                                     (delete id roost--search-expanded)
                                   (cons id roost--search-expanded)))
    (roost--render-search)))

(defun roost-search-next (&optional count)
  "Move to the next message, or COUNT messages on."
  (interactive "p")
  (let ((step (if (< (or count 1) 0) -1 1)))
    (dotimes (_ (abs (or count 1)))
      (let ((found (save-excursion
                     (beginning-of-line)
                     (catch 'found
                       (while (zerop (forward-line step))
                         (when (get-text-property (point) 'roost-search-line)
                           (throw 'found (point))))))))
        (if found (goto-char found) (user-error "No more messages"))))))

(defun roost-search-previous (&optional count)
  "Move to the previous message, or COUNT messages back."
  (interactive "p")
  (roost-search-next (- (or count 1))))

;;;; Sidebar

(defvar-keymap roost-sidebar-list-mode-map
  :doc "Keys in the task sidebar."
  :parent roost-dashboard-mode-map
  "S" #'roost-dashboard
  "q" #'roost-sidebar-mode)

(define-derived-mode roost-sidebar-list-mode roost-dashboard-mode "Roost Sidebar"
  "A compact list of tasks, kept at the left of each frame.
Task commands act on the task at point, as in the dashboard.
\\{roost-sidebar-list-mode-map}"
  (setq-local header-line-format nil
              mode-line-format nil
              ;; The cursor shows only while you are in the sidebar, as
              ;; does the highlight; modal editing shows its state with it.
              cursor-in-non-selected-windows nil)
  ;; Its title, in the header line so that a long list doesn't scroll it
  ;; away, looks as it would in the buffer, in a window you are in or not
  ;; (`header-line-active' and `-inactive' are Emacs 31's).
  (dolist (face '(header-line header-line-active header-line-inactive))
    (when (facep face)
      (face-remap-add-relative face 'default)))
  (remove-hook 'window-size-change-functions #'roost--dashboard-resized t)
  (add-hook 'window-size-change-functions #'roost--sidebar-resized nil t)
  (add-hook 'post-command-hook #'roost--mark-selection nil t)
  (add-hook 'window-selection-change-functions #'roost--sidebar-entered nil t))

(defvar-local roost--selection nil
  "Overlay on the line you are on, while this buffer's window is selected.")

(defun roost--mark-selection (&rest _)
  "Highlight the line at point while the selected window shows this buffer.
The sidebar and task panels have no mode line, so this shows that you
are in one."
  (let ((window (selected-window)))
    (if (not (eq (window-buffer window) (current-buffer)))
        (when roost--selection
          (delete-overlay roost--selection))
      (unless roost--selection
        (setq roost--selection (make-overlay 1 1))
        (overlay-put roost--selection 'face 'roost-selection))
      (overlay-put roost--selection 'window window)
      (save-excursion
        (goto-char (window-point window))
        (move-overlay roost--selection (line-beginning-position)
                      (min (point-max) (1+ (line-end-position))) (current-buffer)))))
  ;; A light in the text, having no transparency, paints the highlight
  ;; behind it while it is on the highlighted line.
  (when-let* ((at (text-property-not-all (point-min) (point-max) 'roost-light nil)))
    (roost--light-behind (get-text-property at 'roost-light)
                         (if (and roost--selection (overlay-buffer roost--selection)
                                  (<= (overlay-start roost--selection) at)
                                  (< at (overlay-end roost--selection)))
                             'roost-selection 'default))))

(defun roost--selection-changed (window)
  "Highlight, or stop highlighting, the line you are on in WINDOW's buffer."
  (with-current-buffer (window-buffer window)
    (roost--mark-selection)))

(defun roost--task-row (key)
  "Position of the row for the task with KEY in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    ;; Keys are lists, so compare with `equal'.
    (when-let* ((match (text-property-search-forward 'roost-task key t)))
      (prop-match-beginning match))))

(defun roost--heading-row (directory)
  "Position of the heading for the project in DIRECTORY, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward 'roost-directory directory t)))
      (prop-match-beginning match))))

(defun roost--sidebar-entered (&rest _)
  "Start on a task when you enter the sidebar, then highlight it.
Entering it anywhere but on a task or an offer starts on the task you
are working on, or else the first.  Once in, point may also rest on a
project's heading, where `c' starts a task in that project; so may a
click."
  (when-let* ((buffer (get-buffer roost--sidebar-buffer))
              (window (selected-window))
              ((eq (window-buffer window) buffer)))
    (with-current-buffer buffer
      (unless (or (mouse-event-p last-input-event)
                  (get-text-property (window-point window) 'roost-task)
                  (get-text-property (window-point window) 'roost-offer))
        (when-let* ((row (or (when-let* ((task (roost--frame-task)))
                               (roost--task-row (roost--key task)))
                             (text-property-not-all (point-min) (point-max) 'roost-task nil))))
          (set-window-point window row)))))
  (roost--sidebar-mark-selection))

(defun roost--sidebar-mark-selection (&rest _)
  "Highlight the sidebar line its keys act on, while you are in the sidebar."
  (when-let* ((buffer (get-buffer roost--sidebar-buffer)))
    (with-current-buffer buffer
      (roost--mark-selection))))

(defun roost--sidebar-resized (window)
  "Reflow the sidebar after WINDOW is resized."
  (with-current-buffer (window-buffer window)
    (roost--render-sidebar)))

(defun roost--sidebar-summary (tasks)
  "Short count of TASKS waiting for you, or nil."
  (let ((waiting (seq-count #'roost--waiting-p tasks)))
    (when (> waiting 0)
      (propertize (format "%d waiting" waiting) 'face (roost--waiting-face tasks)
                  'roost-tint (roost--waiting-face tasks)))))

(defun roost--waiting-face (tasks)
  "Face for a count of TASKS waiting: as for the most urgent of them.
An agent asking, then one that failed, then one that finished."
  (cond ((seq-some #'roost--blocked-p tasks) 'roost-status-permission)
        ((seq-some (lambda (task)
                     (and (roost--waiting-p task)
                          (member (roost--attention-status task) '("error" "failed" "crashed" "ci failed"))))
                   tasks)
         'roost-status-failed)
        (t 'roost-status-ready)))

(defvar roost--marked-key 'unset
  "The key of the task the sidebar marks, while it is drawn.
With workspaces, found once for the whole sidebar, not for each row.")

(defun roost--current-task-p (task)
  "Whether TASK is the one you are working on, which the sidebar marks.
With workspaces, the task of the frame you are in: see `roost--frame-task'."
  (equal (roost--key task)
         (cond ((not (roost--workspace-backend)) roost--current-task)
               ((not (eq roost--marked-key 'unset)) roost--marked-key)
               (t (when-let* ((task (roost--frame-task))) (roost--key task))))))

(defun roost--sidebar-row (task width)
  "TASK's sidebar line, within WIDTH columns: its name, then its status.
The status is in its colour when you have something to look at, dim
when there is only something to know, and not there for an agent you
have seen that waits for nothing.  Where its word would leave the name
under a dozen columns, `roost--status-mark' stands for it."
  (let* ((current (roost--current-task-p task))
         (attention (roost--attention-status task))
         (waiting (roost--waiting-p task))
         (face (if waiting
                   (roost--status-face attention)
                 (roost--status-word-face attention)))
         ;; The fewest columns the name takes: one, and the ID that tells
         ;; it from a task of the same name.
         (least (string-width (roost--row-name task 1)))
         ;; Under the task it was started from, as far as leaves room for
         ;; those, a space and the column of a status's mark.
         (indent (let ((nested (roost--nesting-indent task)))
                   (substring nested 0 (min (length nested) (max 0 (- width 1 least 2))))))
         ;; After an indent.
         (room (- width 1 (length indent)))
         (idle (equal attention "idle"))
         ;; For an agent you have seen that waits for nothing, what changed
         ;; since you last looked, if anything.
         (status (if idle
                     (and (roost--since-looked-shown-p task) (roost--since-looked-text task))
                   (roost--display-status task)))
         ;; A status shows as its word where the name keeps a dozen columns,
         ;; and as its mark where it would not: the name tells tasks apart.
         ;; What changed since you looked shows only beside the whole name.
         (fits (lambda (label &optional whole)
                 (>= room (+ (if whole
                                 (string-width (roost--row-name task))
                               (min (string-width (roost--row-name task)) 12))
                             1 (string-width label)))))
         ;; A worktree on another branch, which the panel says first: here
         ;; too, for every task at once, while its agent isn't at work and
         ;; no louder word is there.  Merging and retiring act on the
         ;; task's branch, so until it is back they are refused.
         (astray (and (or idle (member status '("stopped" "exited" "merged")))
                      (not (roost--field task 'worktreeMissing))
                      (when-let* ((branch (roost--other-branch task)))
                        (propertize (if (equal branch "HEAD") "detached"
                                      (concat "on " (truncate-string-to-width branch 14 nil nil "…")))
                                    'face 'roost-status-permission))))
         (label (cond (astray (if (funcall fits astray) astray
                                (propertize "!" 'face 'roost-status-permission)))
                      ((not status) nil)
                      (idle (seq-find (lambda (text) (funcall fits text t))
                                      (list status (roost--since-looked-text task t))))
                      ((funcall fits status) status)
                      (t (roost--status-mark attention waiting))))
         (name (roost--row-name task (if label (max 1 (- room (string-width label) 1)) room)
                                (if current 'roost-heading 'default))))
    (let ((row (concat " " indent name
                       (when label
                         (concat (make-string (max 1 (- room (string-width name) (string-width label))) ?\s)
                                 ;; With a mark's own weight.  As in the
                                 ;; dashboard, the word of an agent that
                                 ;; can't go on without you, or failed, is
                                 ;; on a tint of its colour.
                                 (propertize label 'face
                                             (if-let* ((own (get-text-property 0 'face label)))
                                                 (delq nil (list own face))
                                               face)
                                             'roost-tint
                                             (and (equal label status) (not idle)
                                                  (car (memq (roost--status-word-face attention)
                                                             '(roost-status-permission
                                                               roost-status-failed))))))))))
      (setq row (roost--tint-marked row))
      ;; Behind the row's own faces, so its status keeps its colour.
      (when current
        (add-face-text-property 0 (length row) 'roost-current t row))
      row)))

(defun roost--sidebar-project-row (directory width)
  "The sidebar's line for project DIRECTORY, within WIDTH columns.
A click on it, or RET, drafts a task there.  Nil DIRECTORY is the line
for any other directory, which asks for a host and a folder first."
  (let* ((host (when directory (ignore-errors (roost--directory-host directory))))
         (label (truncate-string-to-width
                 (if directory
                     (format "%s · %s" (roost--host-label host)
                             (file-name-nondirectory (directory-file-name (file-local-name directory))))
                   "Other directory…")
                 (- width 3) nil nil "…"))
         (row (list 'roost-project (or directory 'other) 'roost-directory directory
                    'keymap roost--project-row-map
                    'help-echo (if directory
                                   (format "New task in %s\nmouse-1: new task · mouse-3: forget"
                                           (roost--project-label directory))
                                 "New task in a directory you choose: its host, then a folder there"))))
    (concat (apply #'propertize
                   (concat " " label (make-string (max 1 (- width (string-width label) 2)) ?\s) "+")
                   'face 'roost-dim 'mouse-face 'highlight row)
            ;; Without `mouse-face', so each row lights up alone.
            (apply #'propertize "\n" row))))

(defun roost--render-sidebar ()
  "Render the task sidebar from cached state, keeping point on its row."
  ;; A sidebar drawn before Roost was loaded again may have lights, and a
  ;; margin for them, which it has no more.
  (roost--light-margins t)
  (roost--lights-forget 'sidebar nil)
  (let* ((window (get-buffer-window (current-buffer) t))
         (width (max 12 (roost--narrowest-width roost-sidebar-width)))
         (position (if window (window-point window) (point)))
         (key (get-text-property position 'roost-task))
         (offer (get-text-property position 'roost-offer))
         (heading (unless (or key offer) (get-text-property position 'roost-directory)))
         (other (eq (get-text-property position 'roost-project) 'other))
         (conversation (get-text-property position 'roost-new-conversation))
         (tasks (roost-tasks))
         (roost--marked-key (if (roost--workspace-backend)
                                (when-let* ((task (roost--frame-task))) (roost--key task))
                              'unset))
         (roost--name-counts (roost--count-names))
         (roost--mark-glyphs (roost--mark-glyphs))
         ;; The line each window showing it starts at, which erasing loses.
         (starts (mapcar (lambda (shown) (cons shown (line-number-at-pos (window-start shown))))
                         (get-buffer-window-list (current-buffer) nil t)))
         (inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format
          (list (string-replace
                 "%" "%%"
                 ;; From where the text starts, past a margin for lights.
                 (roost--tint-marked
                  (concat (propertize " " 'display '(space :align-to 0))
                          (propertize "Roost" 'face 'roost-title)
                          (if-let* ((summary (roost--sidebar-summary tasks))) (concat "  " summary) "")
                          ;; A space after, which pads the count's tint.
                          (if roost-watch-mode " " (propertize "  paused" 'face 'roost-dim)))))))
    ;; Ruled off from the tasks under it, to the window's edge.
    (when-let* ((colour (roost--hairline)))
      (let ((rule (list :underline (list :color colour :position t))))
        (setq header-line-format
              (list (let ((title (copy-sequence (car header-line-format))))
                      (add-face-text-property 0 (length title) rule t title)
                      title)
                    (propertize " " 'display '(space :align-to right) 'face rule)))))
    (roost--insert-unreachable-hosts tasks width t)
    (if (null tasks)
        (insert "\n" (propertize (substitute-command-keys
                                  "No tasks.  \\<roost-sidebar-list-mode-map>\\[roost-new-task] starts one.")
                                 'face 'roost-dim)
                "\n")
      (dolist (group (roost--task-groups tasks))
        (let* ((host (caar group)) (repo (cadar group)) (start (1+ (point)))
               (label (truncate-string-to-width
                       (format "%s · %s" (roost--host-label host)
                               (if (roost--conversation-p (cadr group))
                                   "Conversations"
                                 (file-name-nondirectory (directory-file-name (or repo "?")))))
                       (- width 2) nil nil "…")))
          (insert roost--gap (propertize label 'face (if (gethash host roost--errors)
                                                   'roost-status-failed 'roost-dim))
                  (make-string (max 1 (- width (string-width label) 1)) ?\s))
          (if (roost--conversation-p (cadr group))
              (insert-text-button "+" 'face 'roost-dim 'follow-link t
                                  'help-echo "New conversation"
                                  'action (lambda (_) (roost-new-conversation host)))
            (insert-text-button "+" 'face 'roost-dim 'follow-link t
                                'help-echo (format "New task in %s" (or repo "this project"))
                                'action (lambda (button)
                                          (goto-char (button-start button))
                                          (call-interactively #'roost-new-task))))
          (insert "\n")
          ;; `c' on the heading starts a task in this project; a
          ;; conversation's is none of yours.
          (when (and repo (not (roost--conversation-p (cadr group))))
            (put-text-property start (point) 'roost-directory
                               (roost--project-directory (cadr group))))
          (dolist (task (cdr group))
            (let ((row (list 'roost-task (roost--key task) 'keymap roost--dashboard-row-map)))
              (insert (apply #'propertize (roost--sidebar-row task width)
                             'mouse-face 'highlight
                             'help-echo (format "%s\n%s\n%s · %s\n%smouse-1: open · mouse-3: actions"
                                                (roost--field task 'name)
                                                ;; In full, which a narrow row has no room for.
                                                (roost--with-since-looked task (roost--row-word task))
                                                (roost--host-label host)
                                                (or repo "?")
                                                (roost--large-change-echo task))
                             row)
                      ;; As in the dashboard: unhighlighted, still the task's,
                      ;; and the current task's band reaches the window's edge.
                      (apply #'propertize "\n" (if (roost--current-task-p task)
                                                   (append '(face roost-current) row)
                                                 row)))
              ;; Under one that asks, what it asks: whether to go there now
              ;; turns on that, and its row has room for a word.
              (when-let* (((roost--blocked-p task))
                          (request (roost--permission-request task)))
                (insert (apply #'propertize
                               (concat "   " (truncate-string-to-width (roost--one-line request)
                                                                       (max 4 (- width 4)) nil nil "…"))
                               'face 'roost-dim 'mouse-face 'highlight
                               'help-echo (concat request "\nmouse-1: open · mouse-3: actions")
                               row)
                        (apply #'propertize "\n" row)))
              (dolist (offer (roost--offers task))
                (roost--insert-offer-row task offer (roost--sidebar-offer-row task offer width))))))))
    ;; A conversation needs no project, so it comes before them.
    (insert roost--gap)
    ;; Cut where a narrow sidebar would cut it, with a sign that it was.
    (insert-text-button (truncate-string-to-width " New conversation" (max 4 (1- width)) nil nil "…")
                        'face 'roost-dim 'follow-link t 'mouse-face 'highlight
                        'roost-new-conversation t
                        'help-echo "Talk to an agent in no project: mouse-1 opens its terminal"
                        'action (lambda (_) (roost-new-conversation)))
    ;; Its end of line too, where point is after a click or C-e.
    (insert (propertize "\n" 'roost-new-conversation t))
    (when (> (or roost-sidebar-recent-projects 0) 0)
      (insert roost--gap (propertize "Start a task in" 'face 'roost-dim) "\n")
      (dolist (directory (roost--recent-projects tasks))
        (insert (roost--sidebar-project-row directory width)))
      (insert (roost--sidebar-project-row nil width)))
    ;; The end of a buffer takes the keys of its last character: this one
    ;; has none of a row's, for a click on the space below the rows.
    (insert "\n")
    (goto-char (or (and key (roost--task-row key))
                   ;; One no longer waiting leaves you on its task.
                   (and offer (or (roost--offer-row offer) (roost--task-row (car offer))))
                   (and heading (roost--heading-row heading))
                   (and other (text-property-any (point-min) (point-max) 'roost-project 'other))
                   (and conversation (text-property-any (point-min) (point-max) 'roost-new-conversation t))
                   (point-min)))
    (when window (set-window-point window (point)))
    (pcase-dolist (`(,shown . ,line) starts)
      (set-window-start shown (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)) t))
    ;; Each sidebar you aren't in goes to the task you work on once it
    ;; changes, so that its band shows however many tasks there are; one
    ;; you scrolled since stays where you left it.
    (dolist (shown (get-buffer-window-list (current-buffer) nil t))
      ;; With workspaces, each frame's own task.
      (let ((current (if (roost--workspace-backend)
                         (with-selected-frame (window-frame shown)
                           (when-let* ((task (roost--frame-task))) (roost--key task)))
                       roost--current-task)))
        (unless (or (eq shown (selected-window))
                    (equal (window-parameter shown 'roost-followed) current))
          ;; Followed once its row is there, as a new task's may not be yet.
          (unless current (set-window-parameter shown 'roost-followed nil))
          (when-let* ((row (and current (roost--task-row current))))
            (set-window-parameter shown 'roost-followed current)
            (set-window-point shown row)
            ;; Scrolled no further than it shows the row, at the bottom:
            ;; the top, with the hosts it can't reach, stays as long as
            ;; it can.
            (let ((height (window-body-height shown))
                  (top (line-number-at-pos (window-start shown)))
                  (at (line-number-at-pos row)))
              (unless (and (>= at top) (< at (+ top height)))
                (set-window-start shown (save-excursion (goto-char row) (forward-line (- 1 height)) (point))
                                  t)))))))
    ;; Redrawing removed the highlight with the text.
    (roost--sidebar-mark-selection)))

(defun roost--sidebar-get-buffer ()
  "The task sidebar buffer, rendered."
  (with-current-buffer (get-buffer-create roost--sidebar-buffer)
    (unless (derived-mode-p 'roost-sidebar-list-mode) (roost-sidebar-list-mode))
    (roost--render-sidebar)
    (current-buffer)))

(defun roost--side-window-alist (side width)
  "Display action entries for a pinned Roost window on SIDE, WIDTH wide."
  `((side . ,side) (slot . 0) (window-width . ,width) (preserve-size . (t . nil))
    (dedicated . t)
    ;; Each names its task or Roost at the top, so a mode line or a
    ;; `global-tab-line-mode' tab adds nothing.
    (window-parameters . ((no-delete-other-windows . t) (mode-line-format . none)
                          (tab-line-format . none)))))

(defun roost--show-side-window (buffer side width)
  "Show BUFFER in a pinned window on SIDE, WIDTH wide, and return the window."
  (when-let* ((window (display-buffer-in-side-window
                       buffer (roost--side-window-alist side width))))
    ;; Reusing the window for another buffer clears its dedication, and
    ;; other buffers, such as Magit's, would then take it over.
    (set-window-dedicated-p window t)
    window))

;;;; Side windows

(defun roost--side-frame-p ()
  "Whether Roost may add side windows to the selected frame.
Child frames, minibuffer-only frames and unsplittable ones, such as
Ediff's control frame, are left alone."
  (not (or (frame-parameter nil 'parent-frame)
           (frame-parameter nil 'unsplittable)
           (eq (frame-parameter nil 'minibuffer) 'only))))

(defun roost--main-windows ()
  "The selected frame's windows, other than side windows and the minibuffer."
  (seq-remove (lambda (window) (window-parameter window 'window-side))
              (window-list nil 'nomini)))

(defun roost--frame-task ()
  "Return the task for the selected frame's task panel.
With workspaces, that is the task whose workspace is current, or, in a
workspace that is no task's, the task whose terminal the frame shows: a
frame made with \\[make-frame-command] under perspective.el starts in a
perspective of its own, showing the terminal you were in.  Without
workspaces, it is the task last used in the frame, or taken up since;
see `roost--adopt-shown-task'.  In a child frame, as the box for a
review note is, it is the task of the frame the child is in: a child
has no workspace or task of its own, so the sidebar marked none while
you wrote a note."
  (let ((frame (selected-frame)))
    (while (frame-parent frame)
      (setq frame (frame-parent frame)))
    (with-selected-frame frame
      (if (roost--workspace-backend)
          (or (roost--workspace-task (roost--current-workspace) (roost-tasks))
              (roost--shown-task))
        (gethash (frame-parameter nil 'roost-task) roost--tasks)))))

(defun roost--shown-task ()
  "The task whose terminal the selected frame shows, the one used last.
That is its terminal used last, though Magit or a file was used since."
  (seq-some (lambda (window) (roost--terminal-task (window-buffer window)))
            (sort (roost--main-windows)
                  (lambda (a b) (> (window-use-time a) (window-use-time b))))))

(defun roost--adopt-shown-task ()
  "Take up the task whose terminal the selected frame shows, if its own is gone.
Once the task last used in the frame is gone, as when merged, Emacs shows
another buffer in its place, perhaps another task's terminal: the frame
takes that task up as if opened there, for its panel and the sidebar's
marker, and keeps it when a draft later covers the terminal.  Without
workspaces only, where the frame records its task."
  (unless (or (roost--workspace-backend)
              (gethash (frame-parameter nil 'roost-task) roost--tasks))
    (when-let* ((task (roost--shown-task)))
      (set-frame-parameter nil 'roost-task (roost--key task))
      ;; The task last opened is likely the one gone: the sidebar, one for
      ;; every frame, marks the task opened last, now this one.
      (unless (gethash roost--current-task roost--tasks)
        (setq roost--current-task (roost--key task))))))

(defun roost--task-panel-window ()
  "The task panel docked in the selected frame, if any."
  (seq-find (lambda (window)
              (and (eq (window-parameter window 'window-side) 'right)
                   (with-current-buffer (window-buffer window)
                     (derived-mode-p 'roost-task-info-mode))))
            (window-list)))

(defun roost--task-panel-fits-p (panel)
  "Return non-nil if a task panel would leave 80 columns in the main area.
That is, in its widest window.  PANEL is the panel already docked, if
any; its columns count as free."
  (>= (- (+ (apply #'max 0 (mapcar #'window-body-width (roost--main-windows)))
            (if panel (window-total-width panel) 0))
         roost-task-panel-width)
      80))

(defun roost--close-extra-panels (task buffer docked)
  "Close the selected frame's main windows on TASK's panel BUFFER, now DOCKED.
Such as the one \\<roost-dashboard-mode-map>\\[roost-task-info] showed below a terminal before TASK opened
there.  Each goes as `quit-window' would take it, though not to another
task's terminal, such as the one TASK opened in place of, nor to TASK's
where another window has it, nor to another task's draft, which waits
for its task as when TASK took the frame.  If you were in one, you are
now in DOCKED, unless it went back to TASK's terminal."
  (when-let* ((docked)
              (extra (seq-filter (lambda (window) (eq (window-buffer window) buffer))
                                 (roost--main-windows))))
    (let* ((selected (selected-window))
           (moved-on (lambda (window shown)
                       (when-let* ((own (roost--terminal-task shown)))
                         (or (not (equal (roost--key own) (roost--key task)))
                             (seq-some (lambda (other) (eq (window-buffer other) shown))
                                       (remq window (roost--main-windows)))))))
           (switch-to-prev-buffer-skip
            (lambda (window shown _bury-or-kill)
              (or (eq shown buffer) (funcall moved-on window shown) (roost--draft-task shown)))))
      (dolist (window extra)
        ;; Buried, the panel is left out of what the window goes back to.
        (quit-restore-window window 'bury)
        ;; What it showed before, restored as it was, can be a terminal
        ;; that has moved on, such as the one TASK opened in place of.
        (when (and (window-live-p window) (funcall moved-on window (window-buffer window)))
          (if (eq (window-deletable-p window) t)
              (delete-window window)
            (switch-to-prev-buffer window))))
      (unless (roost--workspace-backend)
        (roost--set-aside-drafts task))
      ;; Quitting selects the window you were in when the panel showed.
      ;; Back on a terminal, you stay there, to talk to its agent.
      (let ((window (if (and (window-live-p selected)
                             (or (not (memq selected extra))
                                 (roost--terminal-task (window-buffer selected))))
                        selected
                      docked)))
        (unless (eq window (selected-window))
          (select-window window))))))

(defun roost--sidebar-wanted-p ()
  "Whether the selected frame should show the sidebar.
With workspaces, only where a task is: in its workspace, or in one that
is no task's while it shows a task's terminal.  A workspace of your own,
such as perspective.el's main, goes without, so that it doesn't look
like a task's."
  (and roost-sidebar-mode
       (or (not (roost--workspace-backend))
           (roost--frame-task))))

(defun roost--sync-side-windows ()
  "Add or remove the selected frame's sidebar and task panel to match.
See `roost-sidebar-mode' and `roost-task-panel-mode'.  This only adds and
removes windows; their contents follow task updates, so a panel you have
scrolled stays where you left it."
  (when (roost--side-frame-p)
    (roost--adopt-shown-task)
    (let ((sidebar (get-buffer-window roost--sidebar-buffer))
          (wanted (roost--sidebar-wanted-p)))
      (cond ((and wanted (not sidebar)
                  (>= (frame-width) (+ roost-sidebar-width 80)))
             (roost--show-side-window (roost--sidebar-get-buffer) 'left roost-sidebar-width))
            ;; A saved workspace can bring back a sidebar after the mode is
            ;; off, or into a workspace that is no task's.
            ((and sidebar (not wanted))
             (when (eq (window-buffer) (get-buffer roost--sidebar-buffer))
               (roost--leave-side-window))
             (dolist (window (get-buffer-window-list roost--sidebar-buffer))
               (when (window-parameter window 'window-side) (delete-window window))))))
    (let* ((panel (roost--task-panel-window))
           (task (and roost-task-panel-mode (roost--frame-task))))
      (cond ((not (and task (roost--task-panel-fits-p panel)))
             (when panel (delete-window panel)))
            ((and panel (equal (buffer-local-value 'roost--buffer-task-key (window-buffer panel))
                               (roost--key task))))
            (t
             (let* ((buffer (roost--task-info-buffer task))
                    (docked (roost--show-side-window buffer 'right roost-task-panel-width)))
               (roost--close-extra-panels task buffer docked)
               ;; Lay it out for its window now rather than at the next resize.
               (with-current-buffer buffer (roost--render-task-info)))
             (unless (assq 'diff task)
               (roost--refresh-host (roost--field task 'host) nil)))))))

(defun roost--sync-all-frames ()
  "Apply `roost--sync-side-windows' to every frame but child frames.
They have no side windows, and each poll comes here."
  (dolist (frame (seq-remove #'frame-parent (frame-list)))
    (with-selected-frame frame (roost--sync-side-windows))))

(defvar roost--layout-timer nil
  "Timer that brings the side windows in step after a layout change.")

(defun roost--layout-changed ()
  "Bring Roost's side windows in step with a changed window layout, soon.
Runs from `window-configuration-change-hook'.  The side windows change
just after redisplay rather than during it: Emacs records window sizes as
its window change hooks finish, so a resize made from one of them would go
unreported to other packages, such as tmux-control resizing a terminal."
  (unless (timerp roost--layout-timer)
    (setq roost--layout-timer
          (run-at-time 0 nil (lambda ()
                               (setq roost--layout-timer nil)
                               (with-demoted-errors "Roost: %S"
                                 (roost--sync-all-frames)
                                 (roost--redraw-moved-panels)))))))

(defun roost--watch-layout ()
  "Keep Roost's side windows in step with the window layout from now on.
Workspace switches, splits, resizes and new frames all change the layout.
Called when Roost first shows a side window, rather than when it loads;
`roost-unload-function' stops it."
  (add-hook 'window-configuration-change-hook #'roost--layout-changed)
  (add-hook 'after-delete-frame-functions #'roost--frame-deleted))

(defun roost--frame-deleted (_frame)
  "Mark the selected frame's task once the task marked is in no frame.
For `after-delete-frame-functions'.  The sidebar, one for every frame,
marks the task opened last; when the frame it was opened in is gone,
the task of the frame you are left in.  With workspaces, it marks the
task whose workspace is current where it was drawn last, perhaps the
frame gone: it is drawn again."
  (cond ((roost--workspace-backend) (roost--redraw))
        ((not (seq-some (lambda (frame)
                          (equal (frame-parameter frame 'roost-task) roost--current-task))
                        (frame-list)))
         (when-let* ((task (roost--frame-task)))
           (setq roost--current-task (roost--key task))
           (roost--redraw)))))

(defun roost--mru-main-window ()
  "The most recently used main window, or nil."
  (car (sort (roost--main-windows)
             (lambda (a b) (> (window-use-time a) (window-use-time b))))))

(defun roost--selected-main-window ()
  "The selected window, or the most recently used main window if a side one."
  (if (window-parameter nil 'window-side)
      (roost--mru-main-window)
    (selected-window)))

(defun roost--leave-side-window ()
  "Select the most recently used main window if a side window is selected.
Tasks open in the main area, never in the sidebar or the task panel."
  (when (window-parameter nil 'window-side)
    (when-let* ((window (roost--mru-main-window)))
      (select-window window))))

;;;###autoload
(define-minor-mode roost-sidebar-mode
  "Keep a compact list of tasks at the left of the frame.
It survives \\[delete-other-windows].  With perspectives or tabs, it
shows in a task's workspace, or one showing a task's terminal, and not
in your own, such as perspective.el's main.  Click a task, or press RET
on it, to open it in the main area; task commands such as `roost-review'
act on the task at point.  Turning the mode on starts
`roost-watch-mode'.  Frames narrower than `roost-sidebar-width' plus 80
columns go without."
  :global t
  (roost--watch-layout)
  (when roost-sidebar-mode (roost-watch-mode 1))
  (roost--sync-all-frames)
  (when roost-sidebar-mode (roost-refresh t))
  (when (called-interactively-p 'any)
    (message (cond ((not roost-sidebar-mode)
                    (substitute-command-keys
                     "Sidebar off; \\<roost-dashboard-mode-map>\\[roost-sidebar-mode] in the dashboard turns it back on"))
                   ((get-buffer-window roost--sidebar-buffer) "Sidebar on")
                   ((not (roost--sidebar-wanted-p)) "Sidebar on; it shows where a task is open")
                   (t (format "Sidebar on, in frames at least %d columns wide"
                              (+ roost-sidebar-width 80)))))))

(defalias 'roost-sidebar #'roost-sidebar-mode)

;;;###autoload
(define-minor-mode roost-task-panel-mode
  "Show the open task's panel to the right of its terminal.
The panel shows what to do next, the prompt and the changes, leaving
the agent's replies to its terminal.
It docks while the terminal keeps at least 80 columns, and steps aside
when a split or a narrower frame would squeeze it.  With workspaces, it
shows the task whose workspace is current.  \\<roost-dashboard-mode-map>\\[roost-task-panel-mode] in the dashboard or sidebar
turns it on, and \\<roost-task-info-mode-map>\\[roost-task-info-quit] in the panel turns it off.  It is off until
you turn it on, since it claims a column beside every task; to have it
from the start, add `(roost-task-panel-mode 1)' to your configuration."
  :global t
  (roost--watch-layout)
  (roost--sync-all-frames)
  (when-let* ((roost-task-panel-mode)
              (task (roost--frame-task))
              ((roost--task-panel-window)))
    (roost--refresh-host (roost--field task 'host) nil))
  (when (called-interactively-p 'any)
    (roost--task-panel-message)))

(defun roost--task-panel-message ()
  "Say whether the task panel is visible, and if not, why."
  (message (cond ((not roost-task-panel-mode)
                  (substitute-command-keys
                   "Task panel off; \\<roost-dashboard-mode-map>\\[roost-task-panel-mode] in the dashboard or sidebar turns it on"))
                 ((roost--task-panel-window) "Task panel on")
                 ((roost--frame-task) "Task panel on, once the terminal has room beside it")
                 (t "Task panel on; it shows beside an open task"))))

(defun roost-task-info-quit ()
  "Close this task panel.
Beside a terminal, that turns off `roost-task-panel-mode'."
  (interactive)
  (if (not (eq (window-parameter nil 'window-side) 'right))
      (quit-window)
    (roost-task-panel-mode -1)
    (roost--leave-side-window)
    (roost--task-panel-message)))

(defun roost-unload-function ()
  "Remove Roost's hooks, advice and side windows for `unload-feature'.
Requests under way go too, as their replies would find no Roost to take them."
  (dolist (process (copy-sequence roost--requests))
    (process-put process 'roost-dropped t)
    (delete-process process))
  (remove-hook 'tmux-control-switch-session-functions #'roost--switch-session)
  (remove-hook 'after-change-major-mode-hook #'roost--keep-terminal-in-its-workspace)
  (remove-hook 'tmux-control-window-buffer-functions #'roost--gather-task-terminals)
  (remove-hook 'persp-switch-hook #'roost--gather-task-terminals)
  (when roost-sidebar-mode (roost-sidebar-mode -1))
  (dolist (frame (frame-list))
    (with-selected-frame frame
      (when-let* ((panel (roost--task-panel-window)))
        (delete-window panel))))
  (remove-hook 'window-configuration-change-hook #'roost--layout-changed)
  (remove-hook 'after-delete-frame-functions #'roost--frame-deleted)
  (when (timerp roost--layout-timer) (cancel-timer roost--layout-timer))
  (when (timerp roost--opening-timer) (cancel-timer roost--opening-timer))
  (remove-hook 'magit-post-refresh-hook #'roost--magit-refreshed)
  (roost--magit-teardown)
  (when roost-watch-mode (roost-watch-mode -1))
  (when (timerp roost--lights-timer) (cancel-timer roost--lights-timer))
  (when (timerp roost--notice-timer) (cancel-timer roost--notice-timer))
  (advice-remove 'persp-mode-line #'roost--compact-perspective-mode-line)
  (dolist (command roost--clicked-commands)
    (define-key transient-predicate-map (vector command) nil t))
  ;; Continue with the standard unloading.
  nil)

;;;; Workload

;; Each host's helper notes when each task's status changes: whether its
;; agent works or waits on you.  From that, `roost-workload' measures how
;; long agents worked, and how long they waited on you, each day.  Past
;; what one person can supervise, another agent adds more waiting on you
;; than work.

(defconst roost--workload-days 7
  "Days `roost-workload' shows, today among them.")

(defconst roost--away 1800
  "Seconds without a change on any host that count as time you were away.
Agents waited then on nobody, as overnight, so `roost-workload' leaves
such stretches out of the time they waited on you.")

(defvar roost--workload-generation 0
  "Counts `roost-workload's requests, so replies to earlier ones are ignored.")

(defvar roost--workload nil
  "What `roost-workload' shows, as a plist.
:since and :now bound it, in seconds since the epoch, and :asked is
when the histories asked for begin, `roost--away' before :since, to
tell whether you were here at its start; :replies has each host's
history, as (HOST . REPLY), REPLY being `pending' or
\(error . MESSAGE) until it comes; :days and :week are what
`roost--workload-tally' makes of it, :days as (START . TALLY) for each
day, today first.")

(defun roost--day-start (time &optional days)
  "The start of the day of TIME, or of DAYS days after it, in seconds."
  (let ((decoded (decode-time time)))
    (setf (decoded-time-second decoded) 0
          (decoded-time-minute decoded) 0
          (decoded-time-hour decoded) 0
          (decoded-time-day decoded) (+ (decoded-time-day decoded) (or days 0))
          ;; Local time as it is that day, across a change to or from DST.
          (decoded-time-dst decoded) -1
          (decoded-time-zone decoded) nil)
    (float-time (encode-time decoded))))

(defun roost--history-waiting-p (status seen turn)
  "Whether a task whose host noted STATUS, SEEN and TURN waited on you.
As `roost--waiting-p' has it: its agent asks you something, or ended a
turn, failed or exited since you last saw it; or once you have seen it,
and it neither works nor asks, its pull request or work waits on you as
TURN, one of `roost--pr-turns' or \"conflicts\", says.  One starting
waits on you after `roost-startup-grace' seconds: see
`roost--history-spans'."
  (or (equal status "permission")
      (and (member status '("ready" "failed" "crashed" "exited")) (not seen))
      (and turn seen (not (member status '("starting" "running" "background" "permission"))))))

(defun roost--history-spans (reply since)
  "What each task in REPLY, a host's history from SINCE, did meanwhile.
A list of (KIND START END), in seconds since the epoch: KIND is `work'
while its agent worked and `wait' while it waited on you, a task's
spans of one kind that follow each other being one.  A task's first
change says what it was before; one that didn't change was as it is now.
None start before the host's history begins: nothing was noted then."
  (let ((now (alist-get 'now reply))
        (since (max since (or (alist-get 'begun reply) (alist-get 'now reply))))
        (changes (make-hash-table :test 'equal))
        spans)
    (dolist (change (alist-get 'changes reply))
      (push change (gethash (alist-get 'id change) changes)))
    (dolist (task (alist-get 'tasks reply))
      (unless (gethash (alist-get 'id task) changes)
        ;; As if it went at NOW, as it was until then.
        (puthash (alist-get 'id task) (list `((at . ,now) (was . ,task) (status))) changes)))
    (maphash
     (lambda (_ list)
       (let* ((list (reverse list))
              (state (alist-get 'was (car list)))
              (start since) (began since) last)
         (dolist (change (append list '(nil)))
           (let* ((end (if change (alist-get 'at change) now))
                  (status (alist-get 'status state)))
             (dolist (span (cond ((>= start end) nil)
                                 ((member status '("running" "background")) `((work ,start ,end)))
                                 ((equal status "starting")
                                  (let ((waits (max start (+ began roost-startup-grace))))
                                    (when (< waits end) `((wait ,waits ,end)))))
                                 ((and status (roost--history-waiting-p status (alist-get 'seen state)
                                                                        (alist-get 'turn state)))
                                  `((wait ,start ,end)))))
               (if (and last (eq (car last) (car span)) (= (nth 2 last) (nth 1 span)))
                   (setcar (nthcdr 2 last) (nth 2 span))
                 (push (setq last (copy-sequence span)) spans)))
             (when change
               (unless (equal (alist-get 'status change) status) (setq began end))
               (setq state change start end))))))
     changes)
    spans))

(defun roost--workload-present (times now)
  "When you were here, as a list of (START . END), from TIMES things changed.
Between two changes, or the last and NOW, `roost--away' seconds or more
apart, you were away."
  (let ((times (sort (cons now (copy-sequence times)) #'<)) present)
    (while (cdr times)
      (let ((from (car times)) (to (cadr times)))
        (when (< (- to from) roost--away)
          (if (and present (= (cdar present) from))
              (setcdr (car present) to)
            (push (cons from to) present))))
      (setq times (cdr times)))
    (nreverse present)))

(defun roost--overlap (start end from to)
  "Seconds START to END shares with FROM to TO."
  (max 0 (- (min end to) (max start from))))

(defun roost--workload-tally (spans present start end)
  "What SPANS, from `roost--history-spans', add up to from START to END.
A plist: :peak, the most agents that worked at once; :work, the seconds
they worked; :wait, the seconds they waited on you while you were
here, as PRESENT, from `roost--workload-present', has it; :longest, the
longest any waited on you at a time while you were here."
  (let ((work 0) (wait 0) (longest 0) (at-once 0) (peak 0) edges)
    (pcase-dolist (`(,kind ,from ,to) spans)
      (when (> (roost--overlap from to start end) 0)
        (if (eq kind 'work)
            (progn (cl-incf work (roost--overlap from to start end))
                   (push (cons (max from start) 1) edges)
                   (push (cons (min to end) -1) edges))
          (let ((waited (apply #'+ (mapcar (lambda (here)
                                             (roost--overlap (max from start) (min to end) (car here) (cdr here)))
                                           present))))
            (cl-incf wait waited)
            (setq longest (max longest waited))))))
    ;; One agent's work ending as another's starts is one at a time.
    (dolist (edge (sort edges (lambda (a b) (or (< (car a) (car b))
                                                (and (= (car a) (car b)) (< (cdr a) (cdr b)))))))
      (setq peak (max peak (cl-incf at-once (cdr edge)))))
    (list :peak peak :work work :wait wait :longest longest)))

(defun roost--workload-compute ()
  "Add to `roost--workload' what the hosts that replied say."
  (let* ((since (plist-get roost--workload :since))
         (now (plist-get roost--workload :now))
         (replies (seq-keep (lambda (entry) (and (consp (cdr entry)) (not (eq (cadr entry) 'error))
                                                 (cdr entry)))
                            (plist-get roost--workload :replies)))
         ;; From before SINCE; the tallies count only what follows it.
         (spans (mapcan (lambda (reply)
                          (roost--history-spans reply (or (plist-get roost--workload :asked) since)))
                        replies))
         (present (roost--workload-present
                   (mapcan (lambda (reply) (mapcar (lambda (change) (alist-get 'at change))
                                                   (alist-get 'changes reply)))
                           replies)
                   now)))
    (setq roost--workload
          (plist-put (plist-put roost--workload :week (roost--workload-tally spans present since now))
                     :days (mapcar (lambda (day)
                                     (let ((start (roost--day-start now (- day))))
                                       (cons start (roost--workload-tally
                                                    spans present start
                                                    (min now (roost--day-start now (- 1 day)))))))
                                   (number-sequence 0 (1- roost--workload-days)))))))

(defvar-keymap roost-workload-mode-map
  :doc "Keys for Roost's workload."
  "g" #'roost-workload)

(define-derived-mode roost-workload-mode special-mode "Roost Workload"
  "How long agents worked and waited on you, each day.
\\{roost-workload-mode-map}"
  (setq-local truncate-lines nil word-wrap t)
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-workload-mode roost-evil-state)
  (roost--quiet-display))

(defun roost--workload-duration (seconds)
  "SECONDS as hours and minutes, or a dash for none."
  (let ((minutes (round seconds 60)))
    (cond ((and (= minutes 0) (> seconds 0)) "<1m")
          ((= minutes 0) "–")
          ((< minutes 60) (format "%dm" minutes))
          (t (format "%dh %dm" (/ minutes 60) (% minutes 60))))))

(defun roost--workload-row (label tally &optional face)
  "A row of the workload table for LABEL, from TALLY, LABEL in FACE."
  (let ((work (plist-get tally :work)) (wait (plist-get tally :wait)))
    (concat (propertize (string-pad label 12) 'face face)
            (format "%7s%10s%15s%10s%17s\n"
                    (if (> (plist-get tally :peak) 0) (plist-get tally :peak) "–")
                    (roost--workload-duration work) (roost--workload-duration wait)
                    (roost--workload-duration (plist-get tally :longest))
                    ;; Too little work to say.
                    (if (< work 60) "–" (roost--workload-duration (* 3600 (/ wait work))))))))

(defun roost--render-workload ()
  "Redraw Roost's workload from `roost--workload'."
  (when-let* ((buffer (if (derived-mode-p 'roost-workload-mode) (current-buffer) (get-buffer "*roost workload*"))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (replies (plist-get roost--workload :replies))
            (today (plist-get roost--workload :now)))
        (erase-buffer)
        (insert (propertize "Workload" 'face 'roost-title) "\n\n")
        (cond
         ((null replies) (insert "No hosts to ask.\n"))
         ((seq-some (lambda (entry) (eq (cdr entry) 'pending)) replies)
          (insert (propertize "Asking each host…\n" 'face 'roost-dim)))
         (t
          ;; Ruled off from the days under it, as a table's heading is.
          (insert (roost--ruled (propertize (format "%-12s%7s%10s%15s%10s%17s\n" "" "At once" "Worked"
                                                    "Waited on you" "Longest" "Per hour worked")
                                            'face 'roost-dim)))
          (pcase-dolist (`(,start . ,tally) (plist-get roost--workload :days))
            (insert (roost--workload-row
                     (cond ((= start (roost--day-start today)) "Today")
                           ((= start (roost--day-start today -1)) "Yesterday")
                           (t (format-time-string "%a %-d %b" start)))
                     tally)))
          (insert (roost--workload-row "Week" (plist-get roost--workload :week) 'roost-heading))
          (pcase-dolist (`(,host . ,reply) replies)
            (when (eq (car-safe reply) 'error)
              (insert "\n" (propertize (format "%s didn't answer, so it isn't counted: %s"
                                               (roost--host-label host)
                                               (car (last (split-string (cdr reply) "\n" t))))
                                       'face 'roost-status-failed)
                      "\n")))
          (insert "\n")
          (let ((start (point)) (fill-column 72))
            (insert (propertize
                     (concat "At once is the most agents working at the same time.  Waited on you adds up "
                             "the time agents asked you something, ended a turn or failed before you saw them, "
                             "or had a pull request or conflict for you; "
                             (format "%d minutes with no change on any host count as time away, and are left out.  "
                                     (/ roost--away 60))
                             "Past what you can supervise, a day with more agents at once has more waiting "
                             "on you for each hour they work.\n")
                     'face 'roost-dim))
            ;; Filled, rather than wrapped by the window with a mark at each break.
            (fill-region start (point)))))
        (goto-char (point-min))))))

(defun roost--workload-reply (generation host reply)
  "Take in HOST's REPLY to `roost-workload', and redraw once all have come.
Unless GENERATION, of `roost--workload-generation', is past: `g' asked again."
  (when-let* (((= generation roost--workload-generation))
              (entry (assoc host (plist-get roost--workload :replies))))
    (setcdr entry reply)
    (unless (seq-some (lambda (entry) (eq (cdr entry) 'pending)) (plist-get roost--workload :replies))
      (roost--workload-compute))
    (roost--render-workload)))

;;;###autoload
(defun roost-workload ()
  "Show how long agents worked and waited on you, today and each day before.
Each host's history goes back a month, from when its helper was first
this version; `roost-workload' shows a week.  Waiting on you counts
agents that asked you something, ended a turn or failed before you
looked, or whose pull request or work waited on you, while you were
here: see `roost--away'."
  (interactive)
  (let* ((hosts (roost--hosts))
         (now (float-time))
         (since (roost--day-start now (- 1 roost--workload-days)))
         (generation (cl-incf roost--workload-generation)))
    (setq roost--workload (list :since since :asked (- since roost--away) :now now
                                :replies (mapcar (lambda (host) (cons host 'pending)) hosts)))
    (with-current-buffer (get-buffer-create "*roost workload*")
      (unless (derived-mode-p 'roost-workload-mode) (roost-workload-mode)))
    (unless hosts (roost--workload-compute))
    (roost--render-workload)
    (pop-to-buffer "*roost workload*")
    (dolist (host hosts)
      (roost--request host "history" `((since . ,(- since roost--away)))
                      (lambda (reply) (roost--workload-reply generation host reply))
                      (lambda (err) (roost--workload-reply generation host (cons 'error err)))))))

;;;; Setup check

(defvar roost--doctor-results nil
  "Alist of (HOST . RESULT) for `roost-doctor'.
RESULT is `pending', a list of checks, or (error . MESSAGE).")

(defvar roost--doctor-generation 0
  "Counts runs of `roost-doctor', so that replies to earlier ones are ignored.")

(defvar-keymap roost-doctor-mode-map
  :doc "Keys for the Roost setup check."
  "g" #'roost-doctor)

(define-derived-mode roost-doctor-mode special-mode "Roost Doctor"
  "What Roost needs locally and on each host, with fixes for problems.
\\{roost-doctor-mode-map}"
  (setq-local truncate-lines nil word-wrap t
              ;; Lines go on under their own start, which says enough.
              fringe-indicator-alist (cons '(continuation nil nil) fringe-indicator-alist))
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-doctor-mode roost-evil-state)
  (roost--quiet-display))

(defconst roost--ssh-hints
  '(("Permission denied" . "Set up key-based SSH (ssh-copy-id HOST), or add your key to ssh-agent")
    ("Host key verification failed" . "Connect once with `ssh HOST' to accept its host key")
    ("Could not resolve hostname" . "Check the host name, or add it to ~/.ssh/config")
    ("Connection timed out" . "Check the host is up and reachable")
    ("Connection refused" . "Check that sshd is running on the host")
    ("No reply after" . "Check the host is up and reachable")
    ("python3: " . "Install Python 3.9 or newer on the host")
    ("command not found" . "Install Python 3.9 or newer on the host"))
  "Fixes for common connection errors, matched against the error text.")

(defun roost--library-version (library)
  "Version of LIBRARY from its header, \"installed\" without one, or nil."
  (when-let* ((file (locate-library library)))
    (or (ignore-errors
          (with-temp-buffer
            (insert-file-contents (replace-regexp-in-string "\\.elc\\'" ".el" file) nil 0 4000)
            (lm-header "Version")))
        "installed")))

(defconst roost--tmux-control-version "0.8.2"
  "The oldest tmux-control Roost works with, as its Package-Requires says.")

(defun roost--doctor-local-checks ()
  "List the local checks, each (NAME OK DETAIL HINT PATH)."
  (let ((helper (expand-file-name "scripts/roost_remote.py" roost--package-directory)))
    (delq nil
          (list (list "Emacs" (version<= "29.1" emacs-version) emacs-version
                      "Roost needs Emacs 29.1 or newer")
                (let ((version (roost--library-version "tmux-control")))
                  (list "tmux-control"
                        (and version (ignore-errors (version<= roost--tmux-control-version version)))
                        version
                        (if version
                            (format "Roost needs tmux-control %s or newer: https://github.com/csheaff/tmux-control"
                                    roost--tmux-control-version)
                          "Install tmux-control: https://github.com/csheaff/tmux-control")
                        (locate-library "tmux-control")))
                (list "Eat" (locate-library "eat") (roost--library-version "eat")
                      "Install eat from NonGNU ELPA (tmux-control renders through it)"
                      (locate-library "eat"))
                (list "Magit" (or (locate-library "magit") 'optional) (roost--library-version "magit")
                      "Optional: review (r) falls back to Dired" (locate-library "magit"))
                (list "Host helper" (file-readable-p helper) (if (file-readable-p helper) "found" "missing")
                      "Reinstall Roost with its scripts/ directory" helper)
                (list "Workspaces" 'info
                      (pcase (roost--workspace-backend)
                        ('perspective "a perspective per task (perspective.el)")
                        ('tab-bar "a tab per task (tab-bar-mode)")
                        (_ "none; tasks open in the selected window (see `roost-workspace')"))
                      nil)
                (if (and roost-watch-mode (not roost--watching-on-demand))
                    (list "Watching" t "from the start of the session" nil)
                  (list "Watching" 'optional "once you open Roost"
                        "Optional: (roost-watch-mode 1) in your configuration tells you from the start when an agent needs you"))
                (roost--doctor-notifications)
                (roost--doctor-old-settings)))))

(defconst roost--old-settings
  '((roost-claude-command . "the \"claude\" entry of `roost-agent-commands'")
    (roost-use-perspectives . "`roost-workspace'")
    (roost-session-name . "nothing: each task has a tmux session of its own"))
  "Settings Roost read before 1.0, each with what replaces it.")

(defconst roost--tuning-variables
  '(roost-startup-grace roost-request-timeout roost-watch-unfocused-interval roost-note-box-lines)
  "Options before 1.0, now variables that Customize no longer sets.")

(defun roost--doctor-old-settings ()
  "The setup check's line on settings Roost no longer reads, or nil."
  (when-let* ((old (append
                    (seq-keep (lambda (setting)
                                (when (boundp (car setting))
                                  (format "`%s' (use %s)" (car setting) (cdr setting))))
                              roost--old-settings)
                    (seq-keep (lambda (variable)
                                (when (get variable 'saved-value)
                                  (format "`%s' from Customize (set it with setq)" variable)))
                              roost--tuning-variables)
                    ;; Roost defines it no more, so a face by that name is yours.
                    (when (or (facep 'roost-sidebar-selection)
                              (get 'roost-sidebar-selection 'saved-face)
                              (get 'roost-sidebar-selection 'customized-face))
                      (list "the face `roost-sidebar-selection' (use `roost-selection')")))))
    (list "Old settings" nil (format "%d Roost no longer reads" (length old))
          (concat "Your configuration sets " (string-join old ", ")))))

(defun roost--doctor-notifications ()
  "The setup check's line on how Roost notifies you."
  (cond ((functionp roost-notify-function)
         (list "Notifications" 'info "through `roost-notify-function'" nil))
        ((executable-find "terminal-notifier")
         (if (roost--emacsclient-command nil)
             (list "Notifications" t "terminal-notifier; a click opens the task" nil)
           (list "Notifications" 'optional "terminal-notifier"
                 "Optional: with an Emacs server (M-x server-start), a click opens the task")))
        ((eq system-type 'darwin)
         (list "Notifications" 'optional "macOS's, through osascript; a click can't open the task"
               "Optional: brew install terminal-notifier, for notifications that open their task"))
        ((fboundp 'notifications-notify)
         (list "Notifications" 'info "the desktop's, through D-Bus" nil))
        (t (list "Notifications" 'info "in the echo area" nil))))

(defun roost--doctor-review-check (host)
  "How Magit reaches HOST's tasks, as a check for `roost--doctor-line'.
TRAMP's shell methods make every Git command a round trip, which a
refresh of Magit's status does a dozen times or more."
  (let ((method (ignore-errors
                  (tramp-file-name-method (tramp-dissect-file-name (roost--host-directory host "/"))))))
    (list "Magit" (if (equal method "rpc") t 'optional)
          (format "over TRAMP's %s method" (or method "default"))
          "tramp-rpc makes Magit several times faster: see \"Remote review\" in Roost's manual")))

(defun roost--doctor-line (name ok detail hint &optional path)
  "Insert one check NAME with status OK, DETAIL and HINT; PATH is a tooltip.
In a narrow window, a long detail or hint goes on below its own start."
  (let ((start (point)))
    (insert "  "
            (pcase ok
              ('info (propertize "·" 'face 'roost-dim))
              ('optional (propertize "–" 'face 'roost-dim))
              ('nil (propertize "✗" 'face 'roost-status-failed))
              (_ (propertize "✓" 'face 'roost-status-ready)))
            ;; A long name, such as a project's push check, keeps a space.
            " " (string-pad name 15) " ")
    (insert (propertize (or (if (stringp detail) detail "") "") 'face 'roost-dim
                        'help-echo path 'wrap-prefix (make-string (min 20 (- (point) start)) ?\s))
            "\n"))
  (when (and hint (memq ok '(nil optional)))
    (let ((line (propertize (concat "      " hint "\n")
                            'face (if ok 'roost-dim 'roost-status-permission))))
      ;; What to do about a check that failed, on a band: it is what
      ;; you came to this buffer for.
      (if-let* (((not ok))
                (tint (roost--tint 'roost-status-permission)))
          (insert (propertize (roost--banded line 'roost-status-permission)
                              'wrap-prefix (propertize "      " 'face (list :background tint))))
        (insert (propertize line 'wrap-prefix "      "))))))

(defun roost--render-doctor ()
  "Redraw the setup check from `roost--doctor-results'."
  (when-let* ((buffer (get-buffer "*roost doctor*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (default (roost--agent-name roost-default-agent)))
        (erase-buffer)
        (insert (propertize "Roost setup check" 'face 'roost-title) "\n\n"
                (roost--ruled (concat (propertize "Emacs" 'face 'roost-heading) "\n")))
        (dolist (check (roost--doctor-local-checks))
          (apply #'roost--doctor-line check))
        (dolist (entry roost--doctor-results)
          (let ((result (cdr entry)))
            (insert "\n" (roost--ruled (concat (propertize (roost--host-label (car entry)) 'face 'roost-heading)
                                                "\n")))
            (cond
             ((eq result 'pending) (insert (propertize "  Checking…\n" 'face 'roost-dim)))
             ((eq (car-safe result) 'error)
              (let* ((host (car entry))
                     (hint (cdr (seq-find (lambda (hint) (string-match-p (regexp-quote (car hint)) (cdr result)))
                                          roost--ssh-hints)))
                     ;; A host you don't use, as one copied from an example.
                     (away (cond ((null host) nil)
                                 ;; Creating a task there remembers it too.
                                 ((and (member host roost-hosts) (member host roost--remembered-hosts))
                                  (concat "To stop watching it, take it out of `roost-hosts', then "
                                          (substitute-command-keys "\\[roost-forget-host]")))
                                 ((member host roost-hosts)
                                  "To stop watching it, take it out of `roost-hosts'")
                                 ((member host roost--remembered-hosts)
                                  (substitute-command-keys
                                   "To stop watching it, \\[roost-forget-host]")))))
                (roost--doctor-line (if host "SSH and Python" "Python") nil (cdr result)
                                    (when (or hint away)
                                      (string-join (delq nil (list (and hint (string-replace "HOST" (or host "localhost") hint))
                                                                   away))
                                                   ". ")))))
             (t
              (when (car entry)
                (roost--doctor-line "SSH" t "connected" nil)
                (apply #'roost--doctor-line (roost--doctor-review-check (car entry))))
              (dolist (check result)
                (let* ((name (alist-get 'name check))
                       ;; Agents you don't use by default are optional.
                       (flagged (and (not (alist-get 'ok check)) (alist-get 'optional check)))
                       (optional (or flagged
                                     (and (not (alist-get 'ok check))
                                          (member (downcase name) roost--agents)
                                          (not (equal name default)))))
                       (hint (alist-get 'hint check)))
                  (roost--doctor-line name (cond (optional 'optional) ((alist-get 'ok check)) (t nil))
                                      (alist-get 'detail check)
                                      (cond ((or flagged (not optional)) hint)
                                            ((string-suffix-p "not found" (or (alist-get 'detail check) ""))
                                             (format "Optional: needed only for %s tasks" name))
                                            (t (format "For %s tasks: %s" name hint)))
                                      (alist-get 'path check))))))))
        (insert "\n" (roost--quiet-but-keys
                       (substitute-command-keys
                        "\\<roost-doctor-mode-map>\\[roost-doctor] checks again · C-u \\[roost-doctor] checks another host"))
                "\n")
        (goto-char (point-min))))))

;;;###autoload
(defun roost-doctor (&optional host)
  "Check what Roost needs locally and on each host, and how to fix problems.
With a prefix argument, read a HOST to check (empty for this machine)."
  (interactive
   (list (when current-prefix-arg
           (let ((host (string-trim (read-string "SSH host to check (empty = this machine): "))))
             (if (string-empty-p host) nil host)))))
  (let ((hosts (if (or host current-prefix-arg) (list host) (roost--hosts)))
        (commands (mapcar (lambda (agent) (cons (intern agent) (vconcat (roost--agent-command agent))))
                          roost--agents))
        (generation (cl-incf roost--doctor-generation)))
    (setq roost--doctor-results (mapcar (lambda (host) (cons host 'pending)) hosts))
    (with-current-buffer (get-buffer-create "*roost doctor*")
      (unless (derived-mode-p 'roost-doctor-mode) (roost-doctor-mode)))
    (roost--render-doctor)
    (pop-to-buffer "*roost doctor*")
    (dolist (host hosts)
      (let* ((host host)
             (done (lambda (result)
                     ;; A host down for the last run, say, may be up for this one.
                     (when (= generation roost--doctor-generation)
                       (setf (alist-get host roost--doctor-results nil nil #'equal) result)
                       (roost--render-doctor)))))
        (roost--request
         host "doctor" (list (cons 'commands commands)
                             (cons 'projects (vconcat (roost--host-projects host))))
         done
         (lambda (err) (funcall done (cons 'error err))))))))

;;;###autoload
(defcustom roost-mode-line-count t
  "Whether `roost-watch-mode' shows waiting agents in the mode line.
The count appears in `global-mode-string', which mode lines keep even
when they hide minor modes, and only while some agent waits."
  :type 'boolean)

(defun roost--mode-line-count (&optional plain)
  "\"● Roost:N\" for the agents waiting for you, or nil when none are.
The dot has the colour of the most pressing of them, as for an agent
asking permission; the count is in the mode line's own colour, which
themes keep legible there, as a warning colour may not be.  PLAIN
leaves out the status light, for a count no mode line shows."
  (let ((blocked 0) (waiting 0) (tasks nil))
    (maphash (lambda (_key task)
               (push task tasks)
               (cond ((roost--blocked-p task) (cl-incf blocked))
                     ((roost--waiting-p task) (cl-incf waiting))))
             roost--tasks)
    ;; With nothing waiting, the light leaves the mode line and stops moving.
    (unless (and (> (+ blocked waiting) 0) (roost--animations-p))
      (remhash '(mode-line . waiting) roost--lights))
    (when (> (+ blocked waiting) 0)
      (let ((face (roost--waiting-face tasks)))
        (concat " "
                (propertize (concat
                             ;; A canvas has one background, so the light shows only
                             ;; in the selected window's mode line, and only on a
                             ;; graphical frame; elsewhere the dot.
                             (if (and (not plain) (roost--animations-p) (roost--light-frame-p (selected-frame))
                                      (mode-line-window-selected-p))
                                 (propertize "●" 'face face 'display
                                             (roost--light 'mode-line 'waiting (and (> blocked 0) 'pulse)
                                                           face 'mode-line-active))
                               ;; In the shape the lists give it, where
                               ;; the display draws one.
                               (let ((dot (propertize "●" 'face face)))
                                 (if-let* (((not plain))
                                           (shape (roost--status-shape-image
                                                   (pcase face
                                                     ('roost-status-permission 'asks)
                                                     ('roost-status-failed 'wrong)
                                                     (_ 'turn))
                                                   face)))
                                     (propertize dot 'display shape)
                                   dot)))
                             ;; With a mark while one asks and holds its agent
                             ;; up: colour alone tells that from one that
                             ;; finished only to those who see the colours apart.
                             (format " Roost:%d%s" (+ blocked waiting) (if (> blocked 0) "!" "")))
                            'help-echo (concat (if (> blocked 0)
                                                   (format "%d of %d agents waiting for you %s, which holds %s up"
                                                           blocked (+ blocked waiting)
                                                           (if (= blocked 1) "asks" "ask")
                                                           (if (= blocked 1) "it" "them"))
                                                 "Agents waiting for you")
                                               "; mouse-1 opens the next")
                            'mouse-face 'mode-line-highlight
                            'local-map (make-mode-line-mouse-map 'mouse-1 #'roost-next-waiting))
                " ")))))

(defun roost-mode-line-waiting ()
  "Return \" ● Roost:N \" while agents wait for you, for your own mode line.
Return nil while none wait, or while `roost-watch-mode' is off.  To place
it yourself, set `roost-mode-line-count' to nil and add
\(:eval (and (fboundp \='roost-mode-line-waiting) (roost-mode-line-waiting)))
to `mode-line-format'."
  (and roost-watch-mode (roost--mode-line-count)))

(defconst roost--mode-line-entry '(roost-mode-line-count (:eval (roost--mode-line-count)))
  "The `global-mode-string' entry for `roost-watch-mode'.")

(defun roost--in-terminal (command)
  "COMMAND in a task's terminal, and nil elsewhere.
A key filter, so that the key keeps its own meaning in other buffers,
the terminals of other tmux sessions included."
  (and (derived-mode-p 'tmux-control-mode)
       (fboundp 'tmux-control-buffer-session)
       (let ((host (tmux-control-buffer-host))
             (socket (tmux-control-buffer-socket-name))
             (session (tmux-control-buffer-session)))
         (seq-some (lambda (task)
                     (and (equal (roost--field task 'session) session)
                          (equal (roost--field task 'host) host)
                          (equal (roost--field task 'socket) socket)))
                   (roost-tasks)))
       command))

(defvar-keymap roost-watch-mode-map
  :doc "Roost's keys while it watches.
In a task's terminal, where every other key goes to its agent,
\\`C-c ?' opens Roost's menu for the task."
  "C-c ?" '(menu-item "" roost-dispatch :filter roost--in-terminal))

;;;###autoload
(define-minor-mode roost-watch-mode
  "Watch tasks asynchronously, retaining cached records during disconnects.
While watching, the mode line counts the agents waiting for you (see
`roost-mode-line-count'), Roost notifies you when one needs you, and
\\`C-c ?' in an agent's terminal opens Roost's menu.  Opening the
dashboard or sidebar, or starting a task, turns this on; turn it on in
your configuration to be told from the start of each session.  It
refreshes every `roost-watch-interval' seconds while Emacs has focus,
and every `roost-watch-unfocused-interval' otherwise.  Turning it off
leaves the sidebar marked paused."
  :global t
  ;; Turned on by your configuration, or by something you did since.  A
  ;; second call to turn it on leaves that as it was.
  (cond ((not roost-watch-mode) (setq roost--watching-on-demand nil))
        ((not roost--watch-timer) (setq roost--watching-on-demand (and after-init-time t))))
  (when roost--watch-timer
    (cancel-timer roost--watch-timer)
    (setq roost--watch-timer nil))
  (setq global-mode-string (delete roost--mode-line-entry (ensure-list global-mode-string)))
  ;; The mode line asks for its light again if it still shows it.
  (remhash '(mode-line . waiting) roost--lights)
  (remove-hook 'after-save-hook #'roost--file-saved)
  (when roost-watch-mode
    (setq global-mode-string (append global-mode-string (list roost--mode-line-entry)))
    (add-hook 'after-save-hook #'roost--file-saved)
    ;; Magit on a task's worktree gets notes, keys and a task header.
    (with-eval-after-load 'magit (roost--magit-setup))
    (setq roost--watch-timer
          (run-with-timer roost-watch-interval roost-watch-interval #'roost--watch-tick))))

(defvar roost--last-watch 0
  "When the last background refresh started, as `float-time'.")

(defun roost--watch-tick ()
  "Refresh in the background; less often while no frame has focus.
See `roost-watch-unfocused-interval'."
  (when (or (seq-some #'frame-focus-state (frame-list))
            (>= (- (float-time) roost--last-watch) roost-watch-unfocused-interval))
    (setq roost--last-watch (float-time))
    (roost-refresh t)))

;;;###autoload
(define-obsolete-function-alias 'roost-status #'roost-dashboard "1.0")

(provide 'roost)
;;; roost.el ends here
