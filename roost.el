;;; roost.el --- Run coding agents in Git worktrees and tmux -*- lexical-binding: t; -*-

;; Author: Clay Sheaff
;; Version: 0.8.1
;; Package-Requires: ((emacs "29.1") (tmux-control "0.7.0") (transient "0.4.1"))
;; Keywords: tools, processes
;; URL: https://github.com/csheaff/roost

;;; Commentary:

;; Coding agents run in tmux on the task's host.  Roost owns task lifecycle
;; and observational status events; tmux-control owns rendering.  JSON RPC
;; over SSH is asynchronous.  Files and Magit use TRAMP.  Stopping an agent
;; keeps its work.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'seq)
(require 'easymenu)
(require 'lisp-mnt)
(require 'tramp)
(require 'parse-time)
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
(declare-function magit-log-insert-child-count "magit-log" ())
(declare-function magit-rev-verify "magit-git" (rev))
(declare-function magit-get-upstream-branch "magit-git" (&optional branch))
(declare-function persp-switch "perspective" (name))
(declare-function persp-kill "perspective" (name))
(declare-function persp-remove-buffer "perspective" (buffer &optional persp))
(declare-function persp-current-name "perspective" ())
(declare-function persp-names "perspective" ())
(declare-function persp-format-name "perspective" (name))
(declare-function persp-rename "perspective" (name))
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function svg-create "svg" (width height &rest args))
(declare-function svg-rectangle "svg" (svg x y width height &rest args))
(declare-function svg-line "svg" (svg x1 y1 x2 y2 &rest args))
(declare-function svg-image "svg" (svg &rest props))
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
(defvar magit-status-headers-hook)
(defvar magit-status-sections-hook)
(defvar magit-refresh-buffer-hook)
(defvar magit-buffer-log-args)
(defvar tmux-control-remote-tmux-socket-setup)
(defvar tmux-control-ssh-options)
(defvar tmux-control-session-activity)
(defvar server-process)
(defvar server-socket-dir)
(defvar server-name)
(defvar persp-autokill-buffer-on-remove)
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

(defvar roost-claude-command '("claude")
  "Claude executable and extra arguments; see `roost-agent-commands'.")
(make-obsolete-variable 'roost-claude-command 'roost-agent-commands "0.9")

(defcustom roost-default-agent "claude"
  "Default agent offered when creating a task.
Existing tasks retain their agent."
  :type '(choice (const "claude") (const "codex") (const "pi")))

(defcustom roost-agent-commands '(("claude" "claude") ("codex" "codex") ("pi" "pi"))
  "Executable and extra arguments for each agent, evaluated on the task host.
Such as (\"claude\" \"claude\" \"--model\" \"sonnet\") for Claude Code.
Roost owns worktree, resume and hook flags, and refuses ones that clash."
  :type '(alist :key-type string :value-type (repeat string)))

(defconst roost--agents '("claude" "codex" "pi"))

(defcustom roost-setup-command nil
  "Optional project setup shell command, run before the agent in new worktrees.
May be set directory-locally.  Not rerun on resume.  It runs in the
worktree, with the project's primary checkout in $ROOST_REPO, so it can
copy files Git doesn't track, such as cp \"$ROOST_REPO/.env\" ."
  :type '(choice (const nil) string))

(defcustom roost-branch-prefix "roost/"
  "Prefix for task topic branches, which are named PREFIX<task>-<id>.
Existing tasks keep their branch."
  :type 'string)

(defcustom roost-socket-name nil
  "Tmux socket, or nil to use tmux-control's configured default."
  :type '(choice (const nil) string))

(defvar roost-session-name nil
  "Ignored: each task has a tmux session of its own.")
(make-obsolete-variable 'roost-session-name "each task has a tmux session of its own" "0.9")

(defcustom roost-startup-grace 15
  "Seconds after which a task still starting is taken to be waiting at a prompt.
Agents report nothing until their folder-trust or hook-review prompts
are answered, so a long start usually needs you."
  :type 'number)

(defcustom roost-watch-interval 3
  "Seconds between asynchronous status refreshes."
  :type 'number)

(defcustom roost-watch-unfocused-interval 15
  "Seconds between status refreshes while no Emacs frame has focus.
Notifications can then come that much later; nothing waits on screen."
  :type 'number)

(defcustom roost-request-timeout 60
  "Maximum seconds for a host operation."
  :type 'number)

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

(defcustom roost-sidebar-width 30
  "Width in columns of the task sidebar; see `roost-sidebar-mode'."
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

(defvar roost-use-perspectives t
  "Allow `roost-workspace' to use perspective.el.")
(make-obsolete-variable 'roost-use-perspectives 'roost-workspace "0.9")

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

(defcustom roost-program-status nil
  "Whether Roost reads the status an agent reports to its terminal.
Claude Code 2.1.295 and later reports whether it works, waits on you,
or is done, by the Program Status Protocol (OSC 7501), but only to a
terminal that answers its probe, which tmux does not.  With this on, a
task's agent gets a terminal of its own, relayed to its tmux pane, that
answers.  Its status then shows at once when you press Esc, decline a
request or approve one, which its hooks don't report.  New tasks, and
tasks you resume, follow this."
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
(defface roost-status-running '((t))
  "A task whose agent is working.
Plain, so that a coloured light always means the agent needs you.")
(defface roost-status-failed '((t :inherit error))
  "A task whose agent failed or disappeared.")
(defface roost-status-inactive '((t :inherit shadow))
  "Stopped, exited, starting or offline tasks.")
(defface roost-pr-open '((t :inherit success))
  "Face for an open pull request." :group 'roost)
(defface roost-pr-draft '((t :inherit shadow))
  "Face for a draft pull request." :group 'roost)
(defface roost-pr-merged '((t :inherit font-lock-keyword-face))
  "Face for a merged pull request." :group 'roost)
(defface roost-pr-closed '((t :inherit error))
  "Face for a pull request closed without merging." :group 'roost)
(defface roost-selection '((t :inherit completions-highlight :extend t))
  "The line you are on in the sidebar or a task panel, while you are in it.
Their windows have no mode line to show that you are, and the
sidebar's keys act on this row.")
(define-obsolete-face-alias 'roost-sidebar-selection 'roost-selection "0.9")
(defface roost-current '((t :inherit region :extend t))
  "The sidebar's row for the task you are working on.
It shows whether or not you are in the sidebar, and `roost-selection'
covers it on the line you are on.")
(defface roost-search-match '((t :inherit match))
  "The words searched for, in search results.")
(defface roost-diff-added '((t :inherit success))
  "Inserted line counts.")
(defface roost-diff-removed '((t :inherit error))
  "Deleted line counts.")
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
  "For each host, the request, counted in `roost--list-requests', whose
task list Roost holds, or the newest of them; so a view can tell that a
list asked for after some moment has arrived.")
(defvar roost--errors (make-hash-table :test 'equal)
  "Last refresh error for each unreachable host.")
(defvar roost--statuses (make-hash-table :test 'equal)
  "Last observed status for each task key, for notifications.")
(defvar roost--seen (make-hash-table :test 'equal)
  "For each task key, its `updatedAt' when you last saw its agent.
A ready agent you have seen since its last event is no longer waiting.")
(defvar roost--remembered-hosts nil)
(defvar roost--hosts-loaded nil)
(defvar roost--remembered-projects nil)
(defvar roost--projects-loaded nil)
(defconst roost--sidebar-buffer "*roost sidebar*"
  "Name of the task sidebar buffer; see `roost-sidebar-mode'.")

(defvar roost-sidebar-mode)
(defvar roost-task-panel-mode)
(defvar roost-watch-mode)

(defvar roost--current-task nil
  "Key of the task most recently opened.")
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

(defun roost--json-encode (alist)
  "Serialize ALIST as a JSON object, encoding nil values as null.
`json-serialize' would otherwise encode nil as an empty object."
  (json-serialize (mapcar (lambda (entry) (cons (car entry) (or (cdr entry) :null)))
                          alist)))

(defun roost--read-json-list (file)
  "Return the JSON array in FILE as a list, or nil if it is unreadable.
JSON null becomes nil."
  (when (file-readable-p file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        ;; Older versions wrote the local host as {}; as an alist that
        ;; reads back as nil, which is the local host.
        (json-parse-buffer :array-type 'list :object-type 'alist :null-object nil)))))

(defun roost--write-json-list (file list)
  "Write LIST to FILE as a private JSON array, with nil as null."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file
      (insert (json-serialize (vconcat (mapcar (lambda (item) (or item :null)) list)))))
    (set-file-modes file #o600)))

(defun roost--hosts ()
  "Configured and remembered hosts, without network I/O."
  (unless roost--hosts-loaded
    (setq roost--hosts-loaded t
          roost--remembered-hosts (seq-filter #'string-or-null-p
                                              (roost--read-json-list roost-hosts-file))))
  (delete-dups (append roost-hosts roost--remembered-hosts)))

(defun roost--remember-host (host)
  "Remember HOST across restarts."
  (roost--hosts)
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
  "Parse the last nonempty line of OUTPUT as the protocol response."
  (let ((line (car (last (split-string output "\n" t "[ \t\r]+")))))
    (unless line (error "The host helper returned no response"))
    (json-parse-string line :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defconst roost--pipe-input-limit 4096
  "Bytes of request input written straight to a host command's pipe.
Longer input, such as the helper itself or a long prompt, is read from a
file instead.  Writing it to the pipe would wait, with Emacs frozen,
until ssh had connected and read it: for a host that is down, the whole
connection timeout.")

(defun roost--expire-request (process on-timeout)
  "Kill host request PROCESS, calling ON-TIMEOUT, unless it ends in time.
That is `roost-request-timeout' seconds.  A timer that runs well after
then slept with this computer, through a laptop's sleep or Power Nap; the
request then gets its time again, awake, rather than failing for want of
a reply nobody could send while asleep."
  (let ((deadline (+ (float-time) roost-request-timeout)))
    (process-put process 'roost-timer
                 (run-at-time roost-request-timeout nil
                              (lambda ()
                                (when (process-live-p process)
                                  (if (> (float-time) (+ deadline 5))
                                      (roost--expire-request process on-timeout)
                                    (funcall on-timeout)
                                    (delete-process process))))))))

(defun roost--run (host code input success failure)
  "Execute CODE asynchronously on HOST with INPUT.
Call SUCCESS with the result or FAILURE with an error message."
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
                     (while (accept-process-output stderr-pipe 0 nil t))
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
                                         (let ((response (roost--decode-response stdout)))
                                           (if (alist-get 'ok response)
                                               (list success (alist-get 'result response))
                                             (list failure (or (alist-get 'error response)
                                                               "Host operation failed"))))
                                       (list failure
                                             (cond (timed-out
                                                    (format "No reply after %ss; the operation may still finish on the host, so refresh before retrying"
                                                            roost-request-timeout))
                                                   ((string-empty-p stderr) "Host operation failed")
                                                   (t stderr))))
                                   (error (list failure (error-message-string parse-error))))))
                           (funcall (car outcome) (cadr outcome)))
                       (kill-buffer buffer)
                       (kill-buffer errors))))))
          (push process roost--requests)
          (roost--expire-request process (lambda () (setq timed-out t)))
          (unless input-file
            ;; ssh may have exited already, as for an unknown host; then
            ;; the sentinel reports why.
            (ignore-errors
              (process-send-string process input)
              (process-send-eof process))))
      (error
       (setq finished t roost--requests (delq process roost--requests))
       (when-let* ((timer (and process (process-get process 'roost-timer))))
         (cancel-timer timer))
       (when (and process (process-live-p process)) (delete-process process))
       (when stderr-pipe (delete-process stderr-pipe))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (when (buffer-live-p errors) (kill-buffer errors))
       (when input-file (ignore-errors (delete-file input-file)))
       (funcall failure (error-message-string err))))))

(defun roost--request-wait (host action parameters &optional timeout)
  "Run ACTION with PARAMETERS on HOST and return its result.
For interactive commands that need the answer before prompting.  Signal
a `user-error' with the host's message on failure, or after TIMEOUT
seconds (default 60)."
  (let (done result failure)
    (roost--request host action parameters
                    (lambda (value) (setq result value done t))
                    (lambda (err) (setq failure err done t)))
    (with-timeout ((or timeout 60) (user-error "Roost: %s on %s timed out" action (roost--host-label host)))
      (while (not done) (accept-process-output nil 0.05)))
    (if failure (user-error "%s" failure) result)))

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
own, the main area; otherwise the selected main window.  TASK is nil for
one not yet created."
  (when-let* ((like (or (roost--task-terminal-window task)
                        (roost--selected-main-window))))
    (roost--area-size (if (and (not (roost--task-terminal-window task))
                               (roost--workspace-backend))
                          (window-main-window)
                        like)
                      like)))

(defun roost--request (host action parameters success &optional failure)
  "Run ACTION with PARAMETERS on HOST, installing the versioned helper as needed.
Call SUCCESS with the result, or FAILURE with an error message."
  (let* ((helper (roost--helper))
         (filename (car helper))
         (root roost-state-directory)
         (installation-key (list host root))
         (failure (or failure
                      (lambda (err) (message "Roost %s: %s" (roost--host-label host) err))))
         (invoke
          (lambda (on-failure)
            (roost--run
             host
             (format "import os,runpy,sys; p=os.path.join(os.path.expanduser(%s),%s); sys.argv=[p,'rpc']; runpy.run_path(p,run_name='__main__')"
                     (json-serialize root) (json-serialize filename))
             (roost--json-encode (append (list (cons 'action action) (cons 'root root))
                                         parameters))
             success on-failure)))
         (install-and-invoke
          (lambda ()
            (roost--run
             host
             (format "import os,sys,tempfile,json\nr=os.path.expanduser(%s)\nos.makedirs(r,mode=0o700,exist_ok=True)\np=os.path.join(r,%s)\nfd,t=tempfile.mkstemp(dir=r)\nwith os.fdopen(fd,'wb') as f: f.write(sys.stdin.buffer.read())\nos.chmod(t,0o700)\nos.replace(t,p)\nprint(json.dumps({'ok':True}))"
                     (json-serialize root) (json-serialize filename))
             (cdr helper)
             (lambda (_)
               (puthash installation-key filename roost--installed)
               (funcall invoke failure))
             failure))))
    (if (not (equal (gethash installation-key roost--installed) filename))
        (funcall install-and-invoke)
      (funcall invoke
               (lambda (err)
                 ;; Python could not open the helper: another Emacs pruned
                 ;; it, or the state directory went.  Install it again.
                 ;; Other failures, such as an unreachable host, keep it.
                 (if (not (and (string-search "FileNotFoundError" err)
                               (string-search filename err)))
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

(defun roost--terminal-notifier-arguments (title body task)
  "Arguments for terminal-notifier to show TITLE and BODY about TASK.
A click opens TASK, given an Emacs server, and a newer notification about
TASK replaces this one."
  (append (list "-title" title "-message" body)
          (when task
            (append (list "-group" (concat "roost-" (or (roost--field task 'host) "local")
                                           "-" (roost--field task 'id)))
                    (when-let* ((command (roost--emacsclient-command
                                          `(roost--open-from-notification
                                            ,(roost--field task 'host) ,(roost--field task 'id)))))
                      (list "-execute" command))))))

(defun roost--notify (title body &optional task)
  "Display notification TITLE with BODY, about TASK if given.
With terminal-notifier and an Emacs server, a click on it opens TASK,
and a newer notification about TASK replaces it."
  (cond ((functionp roost-notify-function)
         (funcall roost-notify-function title body))
        ((executable-find "terminal-notifier")
         (apply #'call-process "terminal-notifier" nil 0 nil
                (roost--terminal-notifier-arguments title body task)))
        ((eq system-type 'darwin)
         (call-process "osascript" nil 0 nil "-e"
                       (format "display notification %S with title %S" body title)))
        ((fboundp 'notifications-notify)
         (notifications-notify :title title :body body))
        (t (message "%s: %s" title body))))

(defconst roost--measured-fields
  '(diff dirty files ahead behind update worktreeMissing prStatus gitStamp agentWork merging landed pr)
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
        (dolist (field roost--measured-fields kept)
          (when-let* ((cell (assq field task)))
            (setq kept (cons cell (assq-delete-all field kept)))))))))

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

(defun roost--cache-task (host task)
  "Cache TASK from HOST and notify only on attention transitions."
  (setf (alist-get 'host task) host)
  (setq task (assq-delete-all 'pushed task))
  (when-let* ((old (gethash (roost--key task) roost--tasks)))
    (setq task (roost--newer-name (roost--newer-events task old) old)))
  (let* ((key (roost--key task))
         (old (gethash key roost--tasks))
         (status (roost--field task 'status))
         (previous (gethash key roost--statuses))
         (new-stop (and (equal status "ready")
                        (equal (roost--field task 'lastEvent) "Stop")
                        (not (equal (roost--field task 'updatedAt)
                                    (roost--field old 'updatedAt))))))
    ;; Quiet polls skip Git and the latest reply; keep the last full refresh's.
    (dolist (field '(diff dirty files ahead behind worktreeMissing prStatus lastMessage gitStamp agentWork merging
                            landed))
      (unless (assoc field task)
        (when (assoc field old) (push (assoc field old) task))))
    (if (not (member status '("retired" "forgotten" "discarded")))
        (puthash key task roost--tasks)
      (remhash key roost--tasks)
      (roost--remove-notes (lambda (note) (equal (roost--note-key note) key))))
    ;; Renamed, here or from another Emacs: its workspace and the panels
    ;; follow, before the views are drawn.
    (when (and old (gethash key roost--tasks)
               (not (equal (roost--field old 'name) (roost--field task 'name))))
      (roost--rename-workspace old task)
      (roost--name-panels))
    ;; Record the status before notifying, which may cache this task again.
    (puthash key status roost--statuses)
    (when (and roost-notify previous
               (or (not (equal previous status)) new-stop)
               ;; An agent that has just started waits for a prompt, which
               ;; is no news; one that asks or fails at once is, and polls
               ;; while Emacs is in the background may see only that.
               (or (not (equal previous "starting")) (not (equal status "ready")) new-stop)
               (member status '("ready" "permission" "failed" "crashed" "exited"))
               ;; Not when you are looking at it already.
               (not (when-let* ((watched (roost--watched-task)))
                      (equal (roost--key watched) key))))
      (roost--notify-attention host task status))
    task))

(defun roost--notify-attention (host task status)
  "Notify that TASK on HOST became STATUS.
A ready agent or one asking permission is inspected first, since quiet
polls leave out its latest reply, so the notification can say what it
finished or wants."
  (let ((title (format "Roost: %s — %s" (roost--field task 'name) (roost--status-name task)))
        (label (roost--host-label host)))
    (if (not (member status '("ready" "permission")))
        (roost--notify title (if-let* ((error (roost--field task 'error)))
                                 (concat label " · " (truncate-string-to-width error 160 nil nil "…"))
                               label)
                       task)
      (roost--request
       host "inspect" (list (cons 'id (roost--field task 'id)))
       (lambda (current)
         (setq current (roost--cache-task host current))
         (roost--redraw)
         (roost--notify title
                        (if-let* ((reply (or (roost--permission-request current)
                                             (roost--last-message-summary current))))
                            (concat label " · " (truncate-string-to-width reply 160 nil nil "…"))
                          label)
                        current))
       (lambda (_error) (roost--notify title label task))))))

(defun roost--apply-snapshot (host tasks &optional request)
  "Replace only HOST's cached tasks with a successful snapshot TASKS.
REQUEST is the number of the list request that TASKS answers, as counted
in `roost--list-requests'; without one, TASKS count as asked for now."
  (let ((keys (mapcar (lambda (task) (list host (roost--field task 'id))) tasks)))
    (maphash (lambda (key _)
               (when (and (equal (car key) host) (not (member key keys)))
                 (remhash key roost--tasks)
                 (remhash key roost--statuses)
                 (remhash key roost--seen)
                 (roost--remove-notes (lambda (note) (equal (roost--note-key note) key)))))
             roost--tasks)
    (mapc (lambda (task) (roost--cache-task host task)) tasks)
    (puthash host (max (or request (puthash host (1+ (gethash host roost--list-requests 0)) roost--list-requests))
                       (gethash host roost--snapshots 0))
             roost--snapshots)
    (remhash host roost--errors)))

(defun roost--task-states (host)
  "HOST's cached tasks as an alist of ID to (STATUS UPDATED-AT GIT-STAMP).
Each agent hook event, such as finishing a tool, moves UPDATED-AT; Git
commands in the worktree, such as your commit, change GIT-STAMP."
  (let (states)
    (maphash (lambda (key task)
               (when (equal (car key) host)
                 (push (list (cadr key) (roost--field task 'status)
                             (roost--field task 'updatedAt) (roost--field task 'gitStamp))
                       states)))
             roost--tasks)
    states))

(defvar roost--full-refresh-pending (make-hash-table :test 'equal)
  "Hosts whose full refresh was requested while another request was in flight.")
(defvar roost--failures (make-hash-table :test 'equal)
  "Consecutive refresh failures per host, as (COUNT . RETRY-AFTER).")

(defun roost--refresh-host (host quiet &optional ids)
  "Refresh HOST asynchronously.
QUIET skips Git statistics; otherwise IDS, if non-nil, limits them to
those tasks."
  (if (gethash host roost--refreshing)
      ;; Run the requested full refresh once the in-flight poll returns.
      (unless quiet
        (let ((pending (gethash host roost--full-refresh-pending)))
          (puthash host (if (or (null ids) (eq pending t)) t (seq-union pending ids))
                   roost--full-refresh-pending)))
    (puthash host t roost--refreshing)
    (let ((request (puthash host (1+ (gethash host roost--list-requests 0)) roost--list-requests))
          (revision (gethash host roost--revisions 0))
          ;; Full refreshes ask GitHub too, and quiet polls now and then.
          (pull-requests (if quiet
                             (> (- (float-time) (gethash host roost--pull-requests-asked 0))
                                roost--pull-request-interval)
                           (not ids)))
          (finish (lambda ()
                    (remhash host roost--refreshing)
                    (when-let* ((pending (gethash host roost--full-refresh-pending)))
                      (remhash host roost--full-refresh-pending)
                      (roost--refresh-host host nil (unless (eq pending t) pending))))))
      (when pull-requests (puthash host (float-time) roost--pull-requests-asked))
      (roost--request
       host "list" `((full . ,(cond (quiet :false) (ids (vconcat ids)) (t t)))
                     ,@(when (and quiet pull-requests) '((pullRequests . t))))
       ;; Each ends the refresh even if drawing what it found fails, or
       ;; the host would never be asked again.
       (lambda (tasks)
         (unwind-protect
             (progn
               (remhash host roost--failures)
               (remhash host roost--errors)
               ;; A newer mutation must win over a stale list reply, and a host
               ;; forgotten meanwhile stays forgotten.
               (when (and (= revision (gethash host roost--revisions 0))
                          (member host (roost--hosts)))
                 (let ((before (roost--task-states host)))
                   (roost--apply-snapshot host tasks request)
                   ;; Quiet polls leave out Git statistics.  An agent that reported
                   ;; something, such as finishing an edit, may have changed files,
                   ;; and a commit moves the task's Git stamp: measure those tasks
                   ;; once this poll is done.
                   (when-let* ((quiet)
                               (changed (seq-keep (lambda (state)
                                                    (unless (equal state (assoc (car state) before))
                                                      (car state)))
                                                  (roost--task-states host))))
                     (roost--refresh-host host nil changed))))
               (roost--redraw))
           (funcall finish)))
       (lambda (err)
         (unwind-protect
             (progn
               ;; Once per outage: ssh words a sleeping host's failure differently
               ;; from one poll to the next, and the sidebar shows it meanwhile.
               ;; Its last line says what failed; ssh's earlier ones say less, such
               ;; as that a shared connection broke.  The sidebar's tooltip has all.
               (unless (gethash host roost--errors)
                 (message "Roost %s: %s (M-x roost-doctor checks this host)" (roost--host-label host)
                          (car (last (split-string err "\n" t "[ \t\r]+")))))
               (puthash host err roost--errors)
               ;; Back off from unreachable hosts, up to a minute between attempts.
               (let ((count (1+ (or (car (gethash host roost--failures)) 0))))
                 (puthash host (cons count (+ (float-time)
                                              (min 60 (* roost-watch-interval (expt 2 (1- count))))))
                          roost--failures))
               (roost--redraw))
           (funcall finish)))))))

;;;###autoload
(defun roost-forget-host (host)
  "Stop watching HOST, which Roost remembered when you first used it.
Agents there keep running, and using the host again watches it again.
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
      (setq roost--remembered-hosts (delete host roost--remembered-hosts))
      (roost--write-json-list roost-hosts-file roost--remembered-hosts)
      (dolist (task tasks)
        (remhash (roost--key task) roost--tasks)
        (remhash (roost--key task) roost--statuses))
      (remhash host roost--errors)
      (remhash host roost--failures)
      (roost--redraw)
      (message "Roost no longer watches %s" (roost--host-label host)))))

(defun roost-refresh (&optional quiet)
  "Refresh hosts asynchronously, including Git statistics.
QUIET (used by background polls) skips Git statistics and hosts that
recently failed."
  (interactive)
  (dolist (host (roost--hosts))
    (unless (and quiet (> (or (cdr (gethash host roost--failures)) 0) (float-time)))
      (roost--refresh-host host quiet))))

(defun roost-tasks ()
  "Cached tasks across hosts, without network I/O."
  (let (tasks)
    (maphash (lambda (_ task) (push task tasks)) roost--tasks)
    (sort tasks
          (lambda (a b)
            (string-lessp (concat (roost--host-label (roost--field a 'host))
                                  (roost--field a 'name))
                          (concat (roost--host-label (roost--field b 'host))
                                  (roost--field b 'name)))))))

;;;; Choosing a task

(defconst roost--status-order
  '("permission" "prompt" "ready" "interrupted" "error" "failed" "crashed" "exited" "running"
    "background" "merged" "idle"
    "starting" "stopped")
  "Attention statuses from most to least in need of attention.")

(defun roost--seen-p (task)
  "Whether you have seen TASK's agent since its last event.
Here or in another Emacs: the task's host records it too."
  (when-let* ((updated (roost--field task 'updatedAt)))
    (or (equal (gethash (roost--key task) roost--seen) updated)
        (equal (roost--field task 'seen) updated))))

(defun roost--attention-status (task)
  "TASK's status for attention.
That is \"prompt\" when it has been starting too long, and \"idle\" when
it is ready and you have seen it since, rather than \"ready\"."
  (let ((status (roost--display-status task)))
    (cond ((and (equal status "starting")
                (> (or (roost--seconds-since (roost--field task 'updatedAt)) 0)
                   roost-startup-grace))
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
you last saw it."
  (let ((status (roost--attention-status task)))
    (or (member status '("permission" "prompt" "ready" "interrupted"))
        (and (member status '("error" "failed" "crashed" "exited"))
             (not (roost--seen-p task))))))

(defun roost--mark-seen (task)
  "Record that you have seen TASK's agent as it is now.
Its host records it too, for your other Emacs and the next session."
  (let ((key (roost--key task))
        (updated (roost--field task 'updatedAt)))
    (unless (or (null updated) (roost--seen-p task))
      (puthash key updated roost--seen)
      ;; Only where seeing it stops it waiting: a working agent's every
      ;; event would otherwise send its host a request.
      (when (member (roost--status-name task) '("ready" "interrupted" "error" "failed" "crashed" "exited"))
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

(defun roost--attention-rank (task)
  "Sort rank of TASK by how much it needs attention."
  (or (seq-position roost--status-order (roost--attention-status task)) 99))

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
                   (status (roost--display-status task)))
              (concat "  " (propertize status 'face (roost--status-word-face (roost--attention-status task)))
                      (propertize (concat "  " (truncate-string-to-width
                                                (roost--one-line (roost--field task 'task)) 60 nil nil "…"))
                                  'face 'roost-dim))))))
    (unless tasks
      (user-error "No tasks yet; create one with `roost-new-task'"))
    (cdr (assoc (completing-read
                 prompt
                 (lambda (string predicate action)
                   (if (eq action 'metadata)
                       `(metadata (category . roost-task)
                                  (annotation-function . ,annotate)
                                  (display-sort-function . identity))
                     (complete-with-action action choices string predicate)))
                 nil t)
                choices))))

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

(defun roost--worktree-relative (task file)
  "FILE's path relative to TASK's worktree, or nil if FILE is elsewhere."
  (when-let* ((task (roost--task-in-directory file (list task))))
    (file-relative-name (file-local-name file)
                        (file-name-as-directory (roost--field task 'worktree)))))

(defun roost--task-at-point ()
  "Task selected in the dashboard, terminal, linked Org entry, or workspace."
  (cond
   ;; A search result of a live task is marked like a dashboard row.
   ((derived-mode-p 'roost-dashboard-mode 'roost-search-mode)
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
       (and workspace
            (let ((current (roost--current-workspace)))
              (seq-find (lambda (task) (equal current (roost--workspace-name task))) tasks)))
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
                'help-echo (format "%s%d task workspaces. Click to switch tasks; roost-status shows the dashboard."
                                   (if description (concat description ". ") "")
                                   count))))

(defun roost--compact-perspective-mode-line (original)
  "Collapse task perspectives in ORIGINAL without changing their identity."
  (if (not (and original roost-compact-mode-line (with-no-warnings roost-use-perspectives)
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
  (let ((perspective (and (with-no-warnings roost-use-perspectives) (bound-and-true-p persp-mode)
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
                    (roost-tasks))
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
  "Take the current buffer out of another task's workspace.
For `after-change-major-mode-hook': a terminal reconnecting in the
background is added to whichever perspective is current, so the
buffer list of one task would offer the terminals of the others."
  (when (and (fboundp 'persp-remove-buffer)
             (eq (roost--workspace-backend) 'perspective)
             (fboundp 'tmux-control-buffer-session)
             (tmux-control-buffer-session))
    (let* ((host (tmux-control-buffer-host))
           (socket (tmux-control-buffer-socket-name))
           (session (tmux-control-buffer-session))
           (tasks (seq-filter (lambda (task)
                                (and (equal (roost--field task 'host) host)
                                     (equal (roost--field task 'socket) socket)
                                     (equal (roost--field task 'session) session)))
                              (roost-tasks))))
      (when (and tasks (null (cdr tasks))
                 (not (equal (persp-current-name) (roost--perspective-name (car tasks)))))
        (let ((persp-autokill-buffer-on-remove nil))
          (persp-remove-buffer (current-buffer)))))))

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
  (roost--watch-layout)
  (roost--sync-side-windows)
  ;; The sidebar marks the task now, rather than once its host replies.
  (when-let* ((sidebar (get-buffer roost--sidebar-buffer)))
    (with-current-buffer sidebar
      (when (derived-mode-p 'roost-sidebar-list-mode)
        (roost--render-visible #'roost--render-sidebar))))
  (when (roost--task-panel-window)
    (roost--refresh-host (roost--field task 'host) nil)))

(defvar roost--held-for-minibuffer 0
  "How many things Roost holds back until the minibuffer is done.
Such as a task to show, by `roost--when-out-of-minibuffer'.")

;;;###autoload
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
      (add-hook 'minibuffer-exit-hook done))))

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

(defun roost-open-task (&optional task quit-questions)
  "Validate TASK's tmux ownership, then restore its perspective and terminal.
With QUIT-QUESTIONS, as when you give a command, first quit the
questions you left open in the minibuffer, which would hold the task
back, unseen, until you answered them."
  (interactive (list nil t))
  (when (and quit-questions (roost--questions-left-open))
    ;; The task at point is where you are now, before quitting gives
    ;; back the windows; asking which comes after, as the question left
    ;; open can keep another from being asked.
    (let ((task (or task (roost--task-at-point))))
      (roost--quit-questions-left-open
       (lambda () (roost-open-task (or task (roost--read-task "Task: ")))))))
  (setq task (roost--choose task))
  (let* ((generation (cl-incf roost--open-generation))
         (window (if (window-minibuffer-p) (minibuffer-selected-window) (selected-window)))
         (shown (window-buffer window)))
    (roost--request (roost--field task 'host) "inspect"
                    (list (cons 'id (roost--field task 'id)))
                    (lambda (current)
                      (setq current (roost--cache-task (roost--field task 'host) current))
                      ;; The reply can be newer than what is shown, as when
                      ;; you answered the agent meanwhile: show it everywhere,
                      ;; the task's panel too, not only where the task opens.
                      (roost--redraw)
                      (roost--when-out-of-minibuffer
                       (lambda ()
                         (when (and (= generation roost--open-generation)
                                    ;; Unless you have shown something else
                                    ;; since, such as tmux-control's pager.
                                    (eq (selected-window) window)
                                    (eq (window-buffer window) shown))
                           (roost--display-task current)
                           (when (and (assq 'live current) (not (roost--field current 'live)))
                             (message "%s's agent has %s; its last output is shown. Resume with `s'."
                                      (roost--field current 'name)
                                      (roost--field current 'status)))))))
                    (lambda (err)
                      ;; Stopped, or its tmux server gone, as after a crash:
                      ;; resuming is the way to its terminal.  Asked once
                      ;; any question you are answering is done, too.
                      (roost--when-out-of-minibuffer
                       (lambda ()
                         (if (and (= generation roost--open-generation)
                                  (string-prefix-p "The agent's tmux window is gone" err))
                             ;; Asked from a timer, not from this reply's
                             ;; sentinel, and only if you haven't moved on
                             ;; or started a question since: a prompt nobody
                             ;; saw held every later switch behind it.
                             (run-at-time
                              0 nil #'roost--when-out-of-minibuffer
                              (lambda ()
                                (when (= generation roost--open-generation)
                                  ;; You know now; `n' moves on to the next.
                                  (roost--mark-seen (or (gethash (roost--key task) roost--tasks) task))
                                  (when (y-or-n-p (format "%s's agent isn't running.  Resume its conversation? "
                                                          (roost--field task 'name)))
                                    (roost-resume task)))))
                           (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err))))))))

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
  (roost--known-projects)
  (setq roost--remembered-projects
        (seq-take (cons directory (delete directory roost--remembered-projects)) 50))
  (roost--write-json-list roost-projects-file roost--remembered-projects))

(defun roost--known-projects ()
  "Project checkouts used for tasks, most recent first, without network I/O."
  (unless roost--projects-loaded
    (setq roost--projects-loaded t
          roost--remembered-projects
          (seq-filter #'stringp (roost--read-json-list roost-projects-file))))
  (delete-dups (append roost--remembered-projects
                       (mapcar #'roost--project-directory (roost-tasks)))))

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

(defun roost--abbreviate-path (path &optional host)
  "PATH with its owner's home directory shown as ~.
The owner is HOST's SSH user, or the local user."
  (let ((user (if (and host (string-match "\\`\\([^@]+\\)@" host))
                  (match-string 1 host)
                user-login-name)))
    (replace-regexp-in-string
     (concat "\\`/\\(?:home\\|Users\\)/" (regexp-quote user) "\\(/\\|\\'\\)") "~\\1" path)))

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
  (or (with-no-warnings
        ;; Set before `roost-agent-commands' had Claude's.
        (and (equal agent "claude") (not (equal roost-claude-command '("claude")))
             roost-claude-command))
      (cdr (assoc agent roost-agent-commands))
      (list agent)))

(defun roost--create-task (directory name base prompt agent &optional on-success on-failure extra)
  "Create an AGENT task NAME in DIRECTORY from BASE with PROMPT.
Call ON-SUCCESS with the task before it opens, or ON-FAILURE with an error.
EXTRA is an alist of further request fields, such as the GitHub issue."
  (setq agent (or agent roost-default-agent))
  (unless (member agent roost--agents)
    (user-error "Unsupported Roost agent: %s" agent))
  (let ((host (roost--directory-host directory))
        (setup (with-temp-buffer
                 (setq default-directory directory)
                 (hack-dir-local-variables-non-file-buffer)
                 roost-setup-command)))
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
           ,(cons 'size (roost--terminal-size))
           ,(cons 'socket (or roost-socket-name
                              (bound-and-true-p tmux-control-default-socket-name)
                              "main"))
           . ,extra)
     (lambda (task)
       (cl-incf (gethash host roost--revisions 0))
       (roost--remember-host host)
       (when (roost--field task 'repo)
         (roost--remember-project (roost--project-directory (cons (cons 'host host) task))))
       (setq task (roost--cache-task host task))
       (when on-success (funcall on-success task))
       (roost-watch-mode 1)
       (roost--redraw)
       (roost-open-task task)
       (message "Roost created %s on %s from %s; integrates into %s"
                name (roost--host-label host)
                (roost--field task 'baseRef) (roost--field task 'integrationBranch)))
     (lambda (err)
       (message "Roost could not create %s: %s" name err)
       (when on-failure (funcall on-failure err))))
    (message "Roost: creating %s…" name)))

;;;###autoload
(defun roost-new-task (&optional directory name base prompt agent)
  "Start a new coding agent task.
Interactively, open a buffer to choose the project, agent and starting
point and to write the prompt; \\<roost-compose-mode-map>\\[roost-compose-submit] creates the task.
An active region, or the Org entry at point, starts the prompt; code is
quoted with its file and lines.  With a prefix argument, the defaults
fork the current task's committed HEAD.

Called with DIRECTORY, create an AGENT task NAME there directly, from
BASE with optional PROMPT.  DIRECTORY may be a TRAMP path.  Nil BASE uses
the primary checkout's current branch, even when DIRECTORY is a task
worktree; explicit HEAD uses DIRECTORY.  Nil AGENT uses
`roost-default-agent'."
  (interactive)
  (if directory
      (roost--create-task directory name base prompt agent)
    (roost--compose current-prefix-arg)))

;;;; Composing a new task

(defconst roost--compose-buffer "*roost new task*")

(defvar-local roost--compose-fields nil
  "Plist of the draft task: :directory :agent :base :name :source.")
(defvar-local roost--compose-body nil
  "Marker at the start of the prompt text.")
(defvar-local roost--compose-timer nil)
(defvar-local roost--compose-submitting nil
  "Non-nil while the drafted task is being created.")

(defvar-keymap roost-compose-mode-map
  :doc "Keys for drafting a new Roost task."
  "C-c C-c" #'roost-compose-submit
  "C-c C-k" #'roost-compose-cancel
  "C-c C-p" #'roost-compose-set-project
  "C-c C-a" #'roost-compose-set-agent
  "C-c C-b" #'roost-compose-set-base
  "C-c C-n" #'roost-compose-set-name
  "C-c C-t" #'roost-compose-set-issue)

(define-derived-mode roost-compose-mode text-mode "Roost New Task"
  "Draft a coding agent task.  Write the prompt below the line.
\\{roost-compose-mode-map}"
  (setq-local header-line-format
              (substitute-command-keys
               " \\[roost-compose-submit] create · \\[roost-compose-cancel] cancel · click a field to change it"))
  (add-hook 'after-change-functions #'roost--compose-changed nil t)
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-compose-mode 'insert)
  (roost--quiet-display))

(defun roost--compose-default-directory (task fork)
  "Default project for a new task, given the TASK in context and FORK.
On a project's heading in the dashboard or sidebar, that project."
  (cond (task (if fork (roost--remote-directory task) (roost--project-directory task)))
        ((get-text-property (point) 'roost-directory))
        ;; On a host TRAMP has not connected to yet, looking there would
        ;; connect, while you wait: then a project Roost knows the directory
        ;; is in, by name.
        ((and (roost--may-look-in-p default-directory) (ignore-errors (vc-root-dir))))
        ((roost--known-project-of default-directory))
        ;; Buffers VC does not track, such as Dired or a shell, in a checkout.
        ((when-let* (((roost--may-look-in-p default-directory))
                     (root (ignore-errors (locate-dominating-file default-directory ".git"))))
           (file-name-as-directory (expand-file-name root))))
        ((car (roost--known-projects)))))

(defun roost--may-look-in-p (directory)
  "Whether looking in DIRECTORY opens no connection: it is local, or on a
host TRAMP is connected to."
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
   ((use-region-p)
    (let* ((start (region-beginning))
           (end (region-end))
           (last (if (and (> end start) (eq (char-before end) ?\n)) (1- end) end))
           (text (buffer-substring-no-properties start end)))
      (if (derived-mode-p 'prog-mode)
          (cons (format "\n\n%s:%d-%d\n\n%s"
                        (if buffer-file-name
                            (file-relative-name (file-local-name buffer-file-name)
                                                (file-local-name
                                                 (or (ignore-errors (vc-root-dir)) default-directory)))
                          (buffer-name))
                        (line-number-at-pos start) (line-number-at-pos last)
                        (string-trim-right text))
                t)
        (cons (string-trim text) nil))))
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

(defun roost--org-marker ()
  "Marker at the Org heading at point or on the agenda line, or nil."
  (cond ((and (derived-mode-p 'org-mode) (not (org-before-first-heading-p)))
         (save-excursion (org-back-to-heading t) (point-marker)))
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

(defun roost--compose (&optional fork)
  "Open the new task buffer.  FORK defaults to the current task's HEAD."
  (let* ((task (roost--task-at-point))
         (fork (and fork task))
         (seed (roost--compose-seed))
         (org (and seed (not (use-region-p)) (roost--org-marker)))
         ;; Where you are, before the draft becomes the current buffer.
         (directory (roost--compose-default-directory task fork))
         (buffer (get-buffer roost--compose-buffer))
         (fresh (not buffer)))
    (setq buffer (or buffer (get-buffer-create roost--compose-buffer)))
    (with-current-buffer buffer
      (when fresh
        (roost-compose-mode)
        (setq roost--compose-body (copy-marker (point-min))))
      ;; An untouched draft follows the current context; a written one is kept.
      (when (or fresh fork (string-empty-p (roost--compose-prompt)))
        (setq roost--compose-fields
              (list :directory directory
                    :agent roost-default-agent
                    :base (when fork "HEAD")
                    :source (when fork (roost--field task 'name)))))
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
A `display-buffer' action, for when the selected window is a tiled
terminal's pane, which BUFFER would not keep."
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
A task started from a GitHub issue leads with the issue's number."
  (or (plist-get roost--compose-fields :name)
      (let ((derived (roost--name-from-prompt (roost--compose-prompt)))
            (issue (alist-get 'number (plist-get roost--compose-fields :issue))))
        (if (and issue (not (string-empty-p derived)))
            (format "%s-%s" issue derived)
          derived))))

(defun roost--compose-field (label value command &optional note)
  "Insert field LABEL showing VALUE as a button running COMMAND, then NOTE."
  (insert (propertize (format "%-9s" label) 'font-lock-face 'roost-dim))
  (insert-text-button value 'action (lambda (_) (call-interactively command))
                      'follow-link t 'font-lock-face 'roost-field
                      'help-echo (format "mouse-1 or RET: change %s" (downcase label)))
  (insert (propertize (concat "  " (substitute-command-keys
                                    (format "\\<roost-compose-mode-map>\\[%s]" command))
                              (if note (concat " · " note) ""))
                      'font-lock-face 'roost-dim))
  (insert "\n"))

(defun roost--compose-render ()
  "Redraw the draft's fields above the prompt, leaving the prompt untouched."
  (let* ((inhibit-read-only t)
         (inhibit-modification-hooks t)
         (buffer-undo-list t)
         (fields roost--compose-fields)
         (derived (roost--compose-name))
         ;; Point's offset into the prompt, so rewriting the fields keeps it.
         (offset (max 0 (- (point) roost--compose-body))))
    (save-excursion
      (delete-region (point-min) roost--compose-body)
      (goto-char (point-min))
      (insert (propertize "New task" 'font-lock-face 'roost-title) "\n\n")
      (let ((directory (plist-get fields :directory))
            (base (plist-get fields :base))
            (name (plist-get fields :name)))
        (roost--compose-field "Project" (if directory (roost--project-label directory) "Choose a project…")
                              #'roost-compose-set-project)
        (roost--compose-field "Agent" (plist-get fields :agent) #'roost-compose-set-agent)
        (roost--compose-field "Start" (cond ((plist-get fields :source)
                                            (format "%s of %s" base (plist-get fields :source)))
                                           (base)
                                           (t "primary checkout's current branch"))
                              #'roost-compose-set-base
                              (when (plist-get fields :source) "fork: includes its commits"))
        (roost--compose-field "Issue" (if-let* ((issue (plist-get fields :issue)))
                                          (format "#%s %s" (alist-get 'number issue)
                                                  (or (alist-get 'title issue) ""))
                                        "none")
                              #'roost-compose-set-issue
                              (when (plist-get fields :issue) "the pull request will close it"))
        (roost--compose-field "Name" (cond (name)
                                          ((string-empty-p derived) "from the prompt")
                                          (t derived))
                              #'roost-compose-set-name
                              (unless (or name (string-empty-p derived)) "from the prompt")))
      (insert (propertize (make-string 60 ?─) 'font-lock-face 'roost-dim) "\n"
              (propertize "Describe the task for the agent below.\n" 'font-lock-face 'roost-dim))
      (add-text-properties (point-min) (point)
                           '(read-only "Write the prompt below the fields" rear-nonsticky t
                             front-sticky t))
      (set-marker roost--compose-body (point)))
    (goto-char (min (point-max) (+ roost--compose-body offset)))))

(defun roost--compose-changed (&rest _)
  "Refresh the derived name soon after each edit to the prompt."
  (unless (plist-get roost--compose-fields :name)
    (when (timerp roost--compose-timer) (cancel-timer roost--compose-timer))
    (let ((buffer (current-buffer)))
      (setq roost--compose-timer
            (run-with-idle-timer 0.3 nil (lambda ()
                                           (when (buffer-live-p buffer)
                                             (with-current-buffer buffer
                                               (roost--compose-render)))))))))

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

(defun roost-compose-set-project ()
  "Choose the draft's project from known checkouts, or any directory.
The checkouts are those Roost has used, then those project.el knows."
  (interactive)
  (let* ((other "Other directory…")
         (choices (append (mapcar (lambda (dir) (cons (roost--project-label dir) dir))
                                  (roost--project-choices))
                          (list (cons other 'other))))
         (choice (roost--choose-from "Project: " choices)))
    (when (eq choice 'other)
      (setq choice (read-directory-name "Project checkout (local or TRAMP): "
                                        (plist-get roost--compose-fields :directory) nil t)))
    (when choice
      (setq roost--compose-fields (plist-put roost--compose-fields :directory
                                             (file-name-as-directory (expand-file-name choice))))
      (roost--compose-render))))

(defun roost-compose-set-agent ()
  "Choose the draft's agent."
  (interactive)
  (when-let* ((agent (roost--choose-from "Agent: " (mapcar (lambda (agent) (cons agent agent))
                                                           roost--agents)
                                         roost-default-agent)))
    (setq roost--compose-fields (plist-put roost--compose-fields :agent agent))
    (roost--compose-render)))

(defun roost-compose-set-base ()
  "Choose the draft's starting Git ref; empty means the primary branch."
  (interactive)
  (let* ((directory (plist-get roost--compose-fields :directory))
         (refs (when directory
                 (ignore-errors
                   (let ((default-directory directory))
                     ;; `process-file' runs Git on the project's host.
                     (with-temp-buffer
                       (when (zerop (process-file "git" nil t nil "for-each-ref"
                                                  "--format=%(refname:short)"
                                                  "refs/heads" "refs/remotes"))
                         (split-string (buffer-string) "\n" t)))))))
         (ref (string-trim (completing-read "Start from ref (empty = primary checkout's branch): "
                                            (cons "HEAD" refs) nil nil))))
    (setq roost--compose-fields
          (plist-put (plist-put roost--compose-fields :base (unless (string-empty-p ref) ref))
                     :source nil))
    (roost--compose-render)))

(defun roost-compose-set-name ()
  "Name the draft; empty derives the name from the prompt."
  (interactive)
  (let ((name (string-trim (read-string "Task name (empty = from the prompt): "
                                        (plist-get roost--compose-fields :name)))))
    (setq roost--compose-fields
          (plist-put roost--compose-fields :name (unless (string-empty-p name) name)))
    (roost--compose-render)))

(defun roost--issue-prompt (issue)
  "Prompt text for GitHub ISSUE: its title, its text, then where it is."
  (let ((body (string-trim (or (alist-get 'body issue) ""))))
    (concat (alist-get 'title issue) "\n\n"
            (if (string-empty-p body) "" (concat body "\n\n"))
            (format "This is GitHub issue #%s: %s" (alist-get 'number issue)
                    (alist-get 'url issue)))))

(defun roost-compose-set-issue ()
  "Start the draft from one of the project's open GitHub issues.
The issue's title and text become the prompt, unless one is already
written, and the task's pull request will close the issue.  Issues are
listed with gh on the project's host."
  (interactive)
  (let* ((directory (or (plist-get roost--compose-fields :directory)
                        (user-error "Choose a project first (%s)"
                                    (substitute-command-keys "\\[roost-compose-set-project]"))))
         (host (roost--directory-host directory))
         (issues (progn (message "Roost: listing open issues on %s…" (roost--host-label host))
                        (roost--request-wait host "issues"
                                             (list (cons 'directory (file-local-name directory))))))
         (none "No issue")
         (choices (mapcar (lambda (issue)
                            (cons (format "#%s %s" (alist-get 'number issue) (alist-get 'title issue))
                                  issue))
                          issues))
         (choices (if (plist-get roost--compose-fields :issue) (cons (cons none nil) choices) choices))
         (completion-extra-properties
          (list :annotation-function
                (lambda (choice)
                  (when-let* ((labels (alist-get 'labels (cdr (assoc choice choices))))
                              ((> (length labels) 0)))
                    (concat "  " (propertize (string-join (append labels nil) ", ")
                                             'face 'roost-dim)))))))
    (unless issues
      (user-error "%s has no open issues" (roost--project-label directory)))
    (let* ((issue (cdr (assoc (completing-read "Issue: " (roost--in-order choices) nil t) choices)))
           (previous (plist-get roost--compose-fields :issue))
           (prompt (roost--compose-prompt)))
      (setq roost--compose-fields (plist-put roost--compose-fields :issue
                                             (when issue
                                               (delq nil (list (assq 'number issue) (assq 'title issue)
                                                               (assq 'url issue))))))
      ;; An untouched prompt follows the issue; a written one gains it below.
      (when issue
        (let ((inhibit-read-only t)
              (untouched (or (string-empty-p prompt)
                             (and previous (equal prompt (string-trim (roost--issue-prompt previous)))))))
          (save-excursion
            (if untouched
                (delete-region roost--compose-body (point-max))
              (goto-char (point-max))
              (insert "\n\n"))
            (goto-char (point-max))
            (insert (roost--issue-prompt issue)))))
      (roost--compose-render))))

(defun roost-compose-cancel ()
  "Discard the draft."
  (interactive)
  (when (or (string-empty-p (roost--compose-prompt))
            (yes-or-no-p "Discard this task draft? "))
    (quit-window t)))

(defun roost-compose-submit ()
  "Create the drafted task.  The draft is kept if creation fails."
  (interactive)
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
    (setq roost--compose-submitting t
          header-line-format (format " Creating %s…" name))
    (roost--create-task (plist-get fields :directory) name (plist-get fields :base) prompt
                        (plist-get fields :agent)
                        (lambda (task)
                          (when-let* ((marker (plist-get fields :org)))
                            (roost--org-link marker task))
                          (when (buffer-live-p buffer)
                            (quit-windows-on buffer t)
                            (when (buffer-live-p buffer) (kill-buffer buffer))))
                        (lambda (err)
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (setq roost--compose-submitting nil)
                              (message "Roost could not create the task: %s" err)
                              (roost--draft-error "Could not create the task" err
                                                  'roost-compose-submit))))
                        (when-let* ((issue (plist-get fields :issue)))
                          (list (cons 'issue issue))))))

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
  (let ((kill-buffer-query-functions nil)
        (switch-to-prev-buffer-skip
         (lambda (_window buffer _bury-or-kill) (roost--terminal-task buffer))))
    (dolist (buffer terminals)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defconst roost--action-messages
  '(("send" . "Sent to %s") ("stop" . "Stopped %s") ("resume" . "Resumed %s")
    ("shell" . "Opened a shell in %s's worktree"))
  "What `roost--act' says once each action is done, for a task's name.
The other actions say more themselves when they finish.")

(defun roost--act (task action &optional parameters callback failure)
  "Run ACTION on TASK with PARAMETERS, then CALLBACK with the updated task.
FAILURE, if given, receives the error message instead of Roost reporting it."
  (let* ((host (roost--field task 'host))
         ;; The host refuses to resume an agent still running, whose
         ;; terminal stays.
         (terminals (when (or (member action '("stop" "retire" "merge" "forget" "discard"))
                              (and (equal action "resume") (not (roost--field task 'live))))
                      (roost--release-terminal task))))
    (roost--request host action (cons (cons 'id (roost--field task 'id)) parameters)
                    (lambda (updated)
                      (roost--discard-terminal terminals)
                      (cl-incf (gethash host roost--revisions 0))
                      ;; `pushed' is transient: the callback sees it, the cache does not.
                      (let ((pushed (assq 'pushed updated)))
                        (setq updated (roost--cache-task host updated))
                        (roost--redraw)
                        (when-let* ((said (cdr (assoc action roost--action-messages))))
                          (message said (roost--field task 'name)))
                        (when callback
                          (funcall callback (if pushed (cons pushed updated) updated)))))
                    (lambda (err)
                      ;; Refused, as retiring unmerged work is: the agent runs on.
                      (when (roost--field task 'live)
                        (roost--restore-terminal task terminals))
                      (if failure
                          (funcall failure err)
                        (message "Roost %s: %s" (roost--host-label host) err))))))

;;;###autoload
(defun roost-resume (&optional task)
  "Restart TASK, resuming its recorded agent conversation."
  (interactive)
  (roost--act (roost--choose task) "resume"
              `((programStatus . ,(if roost-program-status t :false))
                (size . ,(roost--terminal-size task)))
              #'roost-open-task))

;;;###autoload
(defun roost-send (&optional task text)
  "Send TEXT as a literal pasted prompt to TASK's agent pane.
Interactively, write the prompt in a draft buffer, which holds your
review notes for the agent (see `roost-note'); \\<roost-send-mode-map>\\[roost-send-submit] sends it.
While Roost last saw a startup or permission prompt, ask first: the
paste could answer that menu, but agents report no event when a
permission is declined in the terminal."
  (interactive)
  (setq task (roost--choose task))
  (if (and (not text) (called-interactively-p 'any))
      (roost--send-draft task)
    (roost--send-text task (or text (read-string (format "Send to %s: " (roost--field task 'name)))))))

(defun roost--send-text (task text &optional callback failure)
  "Send TEXT to TASK's agent, confirming first if it may be at a prompt.
CALLBACK and FAILURE are passed to `roost--act'."
  (let* ((status (roost--field task 'status))
         (force (when (member status '("starting" "permission"))
                  (or (yes-or-no-p
                       (format "Roost last saw %s %s; send anyway, if you have answered it in the terminal? "
                               (roost--field task 'name)
                               (if (equal status "starting") "starting up" "asking for permission")))
                      (user-error "Open the task with RET to answer it")))))
    (roost--act task "send" (append (list (cons 'text text))
                                    (when force (list (cons 'force t))))
                callback failure)))

;;;; Composing a follow-up

(defvar-local roost--send-task nil
  "The task a follow-up draft will be sent to.")
(defvar-local roost--send-sending nil
  "Non-nil while the drafted follow-up is being sent.")
(defvar-local roost--send-notes nil
  "Identifiers of the review notes in this draft; sending it clears them.")

(defvar-keymap roost-send-mode-map
  :doc "Keys for drafting a follow-up prompt."
  "C-c C-c" #'roost-send-submit
  "C-c C-k" #'roost-send-cancel)

(define-derived-mode roost-send-mode text-mode "Roost Send"
  "Draft a follow-up prompt for a Roost task's agent.
\\{roost-send-mode-map}"
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (roost--evil-state 'roost-send-mode 'insert)
  (roost--quiet-display))

(defun roost--send-header (task)
  "Header line for TASK's follow-up draft."
  (substitute-command-keys
   (format " Send to %s · \\<roost-send-mode-map>\\[roost-send-submit] send · \\[roost-send-cancel] cancel"
           (roost--field task 'name))))

(defun roost--send-draft (task &optional initial)
  "Open a draft buffer for a follow-up to TASK, adding INITIAL.
An existing draft for TASK is reused and kept as written, with INITIAL
after it.  TASK's review notes not yet in the draft follow; sending the
draft clears them (see `roost-note')."
  (let ((buffer (roost--draft-buffer "send" 'roost--send-task task)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-send-mode) (roost-send-mode))
      (setq roost--send-task task
            header-line-format (roost--send-header task))
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

(defun roost-send-cancel ()
  "Discard the follow-up draft."
  (interactive)
  (when (or (string-empty-p (string-trim (buffer-string)))
            (yes-or-no-p "Discard this prompt? "))
    (quit-window t)))

(defun roost-send-submit ()
  "Send the drafted follow-up.  The draft is kept if sending fails.
Review notes in it are cleared once it is sent."
  (interactive)
  (let ((text (replace-regexp-in-string "\\`\\([ \t]*\n\\)+" "" (string-trim-right (buffer-string))))
        (task roost--send-task)
        (notes roost--send-notes)
        (buffer (current-buffer)))
    (when (string-empty-p (string-trim text))
      (user-error "Write a prompt first"))
    (when roost--send-sending
      (user-error "Already sending"))
    (setq roost--send-sending t)
    (condition-case err
        (roost--send-text
         task text
         (lambda (_task)
           (when (roost--remove-notes (lambda (note) (member (alist-get 'id note) notes)))
             (roost--redraw))
           (when (buffer-live-p buffer)
             (quit-windows-on buffer t)
             (when (buffer-live-p buffer) (kill-buffer buffer))))
         (lambda (err)
           (message "Roost could not send to %s: %s" (roost--field task 'name) err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq roost--send-sending nil)
               (roost--draft-error "Could not send" err 'roost-send-submit)))))
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
         (task (or (and buffer-file-name (roost--task-in-directory buffer-file-name))
                   (roost--read-task "Send region to task: "))))
    (roost--send-draft
     task
     (format "%s:%d-%d\n\n%s"
             (cond ((and buffer-file-name (roost--worktree-relative task buffer-file-name)))
                   (buffer-file-name (file-local-name buffer-file-name))
                   (t (buffer-name)))
             (line-number-at-pos start) (line-number-at-pos last)
             (buffer-substring-no-properties start end)))))

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
          roost--notes (seq-filter #'consp (roost--read-json-list roost-notes-file))))
  roost--notes)

(defun roost--save-notes ()
  "Write the review notes to `roost-notes-file'."
  (roost--write-json-list
   roost-notes-file
   (mapcar (lambda (note)
             ;; JSON has no nil: absent fields stay out, and lists are arrays.
             (seq-keep (lambda (field)
                         (when (cdr field)
                           (cons (car field)
                                 (if (consp (cdr field)) (vconcat (cdr field)) (cdr field)))))
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

(defun roost--update-drafts (old new)
  "Replace note OLD with NEW in the drafts holding it; nil NEW removes it.
A draft in which you have changed the note's text keeps your text, and
no longer counts the note as its own, so sending it leaves the note."
  (let ((id (alist-get 'id old))
        (before (roost--format-note old))
        (case-fold-search nil))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'roost-send-mode) (member id roost--send-notes))
          (save-excursion
            (goto-char (point-min))
            ;; The note as it was drafted, on lines of its own.
            (cond ((not (re-search-forward
                         (concat "^\\(" (regexp-quote before) "\\)\\(?:\n\\|\\'\\)")
                         nil t))
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
                            at (not at))))

(defun roost--magit-teardown ()
  "Remove what `roost--magit-setup' added, from Magit and its buffers."
  ;; Removing from a hook Magit has not defined yet would define it empty.
  (when (featurep 'magit)
    (remove-hook 'magit-refresh-buffer-hook #'roost--magit-buffer-refreshed)
    (remove-hook 'magit-status-headers-hook #'roost--magit-insert-task-header)
    (remove-hook 'magit-status-sections-hook #'roost--magit-insert-reply)
    (remove-hook 'magit-status-sections-hook #'roost--magit-insert-unmerged))
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
              ((magit-rev-verify integration)))
    (let ((range (concat integration "..")))
      (roost--magit-insert-section
       'unpushed range nil
       (lambda ()
         (magit-insert-heading
           (format (propertize "Unmerged into %s." 'font-lock-face 'magit-section-heading)
                   integration))
         ;; With no commits, Magit leaves the section out.
         (magit--insert-log nil range magit-buffer-log-args)
         (magit-log-insert-child-count))))))

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
        (goto-char (roost--slot hunk 'content))
        (let ((old (car from)) (new (car to)) (end (roost--slot hunk 'end)) lines)
          (while (< (point) end)
            (let ((text (buffer-substring-no-properties
                         (min (1+ (point)) (line-end-position)) (line-end-position))))
              (pcase (char-after)
                (?- (push (list (point) 'old old text) lines) (cl-incf old))
                (?+ (push (list (point) 'new new text) lines) (cl-incf new))
                (?\s (push (list (point) 'new new text) lines) (cl-incf old) (cl-incf new))))
            (forward-line))
          (nreverse lines))))))

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
                                (buffer-substring-no-properties (point) (line-end-position))))
                            chosen)))))
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
                                  (when rule
                                    (propertize " " 'display '(space :align-to right)
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
                  roost--note-overlays)))))))

(defun roost--magit-file-lines ()
  "For each file in this Magit buffer's diffs, (FILE HEADINGS LINES).
HEADINGS are the ends of its headings, and LINES its lines, from
`roost--hunk-lines'."
  (let (files)
    (magit-map-sections
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
  (when-let* (((bound-and-true-p magit-root-section))
              (entry (assoc (alist-get 'file place) (roost--magit-file-lines)))
              (positions (roost--note-positions place (nth 1 entry) (nth 2 entry))))
    (let* ((here (line-end-position))
           (nearest (car (sort (copy-sequence positions)
                               (lambda (a b) (< (abs (- a here)) (abs (- b here))))))))
      (seq-position positions nearest))))

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

(defun roost--note-id ()
  "A new review note's identifier."
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
  ;; OLD may have been sent, or discarded, while you wrote.
  (unless (memq old (roost--notes)) (setq old nil))
  (cond ((and old (string-empty-p text))
         (roost--remove-notes (lambda (note) (eq note old))))
        ((string-empty-p text))
        (old (roost--edit-note old text))
        (t
         (setq roost--notes
               (append (roost--notes)
                       (list (append `((id . ,(roost--note-id))
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

(defcustom roost-note-box-lines 4
  "How many lines of text the box for writing a review note shows."
  :type 'natnum)

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
                                              (dedicated . t)))))
    (message "%s" (substitute-command-keys
                   "\\<roost-note-box-mode-map>\\[roost-note-box-save] saves the note, \\[roost-note-box-cancel] cancels it"))))

(defun roost--note-box-header ()
  "The heading of the note box: what the note is about, then buttons."
  (let* ((box roost--note-box)
         (old (plist-get box :old))
         (buttons
          (mapconcat
           (pcase-lambda (`(,label ,command ,face ,help))
             (propertize label 'face face 'mouse-face 'highlight 'pointer 'hand
                         'help-echo (substitute-command-keys help)
                         'local-map (define-keymap "<header-line> <mouse-1>" command)))
           (delq nil
                 (list (when old
                         '(" Remove " roost-note-box-remove roost-note-box-button
                           "mouse-1: remove this note"))
                       '(" Cancel " roost-note-box-cancel roost-note-box-button
                         "mouse-1 or \\<roost-note-box-mode-map>\\[roost-note-box-cancel]: close without saving")
                       `(,(if old " Save " " Add note ") roost-note-box-save roost-note-box-default-button
                         "mouse-1 or \\<roost-note-box-mode-map>\\[roost-note-box-save]: save the note")))
           " ")))
    (when box
      (concat " " (if old "Edit the note on " "Note on ")
              (roost--note-location (plist-get box :place))
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
                  (line (posn-at-point (overlay-get overlay 'roost-note-anchor) window))
                  (below (cdr (posn-x-y line)))
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
                (select-window window))))
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
  "Where the diff line at POSITION starts, if notes can be written on it."
  (save-excursion
    (goto-char position)
    (let* ((start (line-beginning-position))
           (section (get-text-property start 'magit-section)))
      (and section
           (magit-section-match 'hunk section)
           (not (roost--slot section 'combined))
           (>= start (roost--slot section 'content))
           (memq (char-after start) '(?+ ?- ?\s))
           start))))

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
           (fill (or (face-foreground 'roost-note-button nil t) "RoyalBlue"))
           (plus (or (face-background 'default nil t) "white"))
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
         (where (let ((posn (posn-at-point (line-end-position))))
                  (if posn
                      (list (list (car (posn-x-y posn)) (+ (cdr (posn-x-y posn)) (default-line-height)))
                            (selected-window))
                    (list '(0 0) (selected-window)))))
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
           (message "Roost could not send the note to %s: %s" (roost--field task 'name) err)))
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
task's worktree, else a diff of the note's file since the task began."
  (let* ((find (lambda ()
                 (seq-find (lambda (buffer) (roost--note-shown-overlay note buffer))
                           (cons (current-buffer)
                                 (seq-filter (lambda (buffer)
                                               (buffer-local-value 'roost-magit-mode buffer))
                                             (buffer-list))))))
         (buffer (or (funcall find)
                     (progn (roost-review task) (funcall find))
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
        (when (eq (window-buffer) buffer) (recenter))))))

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
        (find-file (expand-file-name file (magit-toplevel)))
      (magit-diff-dwim (cons "-U1000000" args) (list file)))))

;;;###autoload
(defun roost-review (&optional task)
  "Open Magit on TASK's worktree, through TRAMP for remote tasks."
  (interactive)
  (setq task (roost--choose task))
  (roost--activate-workspace task)
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
(defun roost-files (&optional task)
  "Browse TASK's worktree with Dired."
  (interactive)
  (setq task (roost--choose task))
  (roost--activate-workspace task)
  (dired (roost--remote-directory task)))

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
  (let ((generation (cl-incf roost--open-generation)))
    (roost--act task "shell" nil
                (lambda (updated)
                  (roost--when-out-of-minibuffer
                   (lambda ()
                     (when (= generation roost--open-generation)
                       (roost--display-task updated (roost--field updated 'shellPaneId))
                       (with-current-buffer (window-buffer (selected-window))
                         (unless (tmux-control-tiled-p) (tmux-control-tile))
                         (roost--focus-shell updated generation)))))))))

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
(defun roost-diff (&optional task)
  "Diff TASK's tracked files against where its own work begins."
  (interactive)
  (setq task (roost--choose task))
  (unless (require 'magit nil t)
    (user-error (substitute-command-keys
                 "The diff needs Magit; \\[roost-review] opens the worktree in Dired instead")))
  (roost--magit-setup)
  (roost--activate-workspace task)
  (let ((default-directory (roost--remote-directory task)))
    (magit-diff-working-tree (roost--fork-point task))))

;;;###autoload
(defun roost-update (&optional task)
  "Merge TASK's integration branch into its worktree.
This brings a task that fell behind up to date before merging it, and
resolves conflicts in the task rather than the primary checkout.  On
conflicts, or changes not yet committed, offer to have the task's
agent do it."
  (interactive)
  (setq task (roost--choose task))
  (roost--act
   task "update" nil
   (lambda (updated)
     (let* ((result (roost--field updated 'update))
            (conflicts (alist-get 'conflicts result))
            (name (roost--field updated 'name))
            (branch (roost--field updated 'integrationBranch)))
       (roost--refresh-host (roost--field updated 'host) nil)
       (cond (conflicts
              (if (y-or-n-p (format "%s conflicts with %s in %s.  Ask its agent to resolve them? "
                                       name branch (string-join conflicts ", ")))
                  (roost-send updated
                              (format "I merged %s into this branch and Git reports conflicts in: %s. Resolve the conflicts so the changes from both sides keep working, run the tests, and commit the merge."
                                      branch (string-join conflicts ", ")))
                (message "The merge is in progress in %s's worktree; resolve it in Magit (r) and commit"
                         name)))
             ((alist-get 'changed result)
              (message "%s now includes the latest %s" name branch))
             (t (message "%s is already up to date with %s" name branch)))))
   (lambda (err)
     (if (not (string-prefix-p "Commit the task's changes before updating" err))
         (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err)
       (let ((name (roost--field task 'name))
             (branch (roost--field task 'integrationBranch)))
         (if (y-or-n-p (format "%s has changes not yet committed.  Ask its agent to commit them and merge %s? "
                                  name branch))
             (roost-send task
                         (format "Commit your changes, then merge %s into this branch. If that conflicts, resolve the conflicts so the changes from both sides keep working. Run the tests, and commit the merge."
                                 branch))
           (message "%s" (substitute-command-keys
                          (format "Commit %s's changes in Magit (\\<roost-task-info-mode-map>\\[roost-review]), then update it again"
                             name)))))))))

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
  (let ((default-directory (roost--remote-directory task)))
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
              (output (roost--git-output task "log" "--reverse" "--no-merges" "--format=%B%x00"
                                         (concat base "..HEAD"))))
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
closes it."
  (let* ((subjects (mapcar (lambda (message) (car (split-string message "\n"))) commits))
         (title (or (car subjects) (roost--readable-name (roost--field task 'name))))
         (first-body (and commits (string-trim (substring (car commits) (length (car subjects))))))
         (body (delq nil (list (if (and first-body (not (string-empty-p first-body)))
                                   first-body
                                 (when-let* ((prompt (roost--prompt-text task))) (string-trim prompt)))
                               (when (cdr subjects)
                                 (mapconcat (lambda (subject) (concat "- " subject)) (cdr subjects) "\n")))))
         (issue (alist-get 'number (roost--field task 'issue))))
    ;; Let GitHub close the task's issue when this merges.
    (when (and issue (not (string-match-p (format "#%s\\b" issue) (string-join body "\n"))))
      (setq body (append body (list (format "Closes #%s" issue)))))
    (concat title "\n\n" (string-join body "\n\n") (if body "\n" ""))))

(defun roost--pr-header (task)
  "Header line for TASK's pull request draft."
  (substitute-command-keys
   (format " Pull request for %s · \\<roost-pr-mode-map>\\[roost-pr-submit] create (C-u: draft) · \\[roost-pr-cancel] cancel"
           (roost--field task 'name))))

(defun roost--pr-draft (task)
  "Open a draft buffer for TASK's pull request.
An existing draft for TASK is reused, and kept as written unless it is empty."
  (let ((buffer (roost--draft-buffer "pr" 'roost--pr-task task)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-pr-mode) (roost-pr-mode))
      (setq roost--pr-task task
            header-line-format (roost--pr-header task))
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
only open it."
  (interactive (list nil current-prefix-arg))
  (setq task (roost--choose task))
  (if-let* ((pr (roost--field task 'pr))
            (url (alist-get 'url pr)))
      (if (or skip-push (memq (roost--pr-state task) '(merged closed)))
          (browse-url url)
        (roost--act
         task "pr" nil
         (lambda (updated)
           (let ((pushed (or (alist-get 'pushed updated) 0))
                 (number (alist-get 'number pr)))
             (if (zerop pushed)
                 (message "Roost: #%s is up to date" number)
               (message "Roost: Pushed %d commit%s to #%s"
                        pushed (if (= pushed 1) "" "s") number)))
           (browse-url url))))
    (roost--pr-draft task)))

(defun roost-pr-cancel ()
  "Discard the pull request draft."
  (interactive)
  (when (or (string-empty-p (string-trim (buffer-string)))
            (yes-or-no-p "Discard this pull request? "))
    (quit-window t)))

(defun roost-pr-submit (&optional draft)
  "Create the drafted pull request; with prefix argument DRAFT, as a draft.
The text is kept if creation fails."
  (interactive "P")
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
    (setq roost--pr-sending t)
    (message "Roost: creating a pull request for %s…" (roost--field task 'name))
    (roost--act
     task "pr" `((title . ,title) (body . ,body) (draft . ,(and draft t)))
     (lambda (updated)
       (when (buffer-live-p buffer)
         (quit-windows-on buffer t)
         (when (buffer-live-p buffer) (kill-buffer buffer)))
       (message "Roost: opened pull request #%s %s"
                (alist-get 'number (roost--field updated 'pr))
                (alist-get 'url (roost--field updated 'pr))))
     (lambda (err)
       (message "Roost could not create the pull request: %s" err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq roost--pr-sending nil)
           (roost--draft-error "Could not create" err 'roost-pr-submit)))))))

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

(defun roost--pr-marker (task)
  "Compact pull request marker for TASK's dashboard row, such as \"#12 ✓\"."
  (if-let* ((pr (roost--field task 'pr))
            (state (roost--pr-state task)))
      (let* ((open (memq state '(open draft)))
             (counts (and open (roost--pr-checks task)))
             (review (and open (alist-get 'review (roost--field task 'prStatus))))
             (parts (delq nil
                          (list (propertize (format "#%s" (alist-get 'number pr))
                                            'face (roost--pr-face state))
                                (when counts
                                  (cond ((> (nth 1 counts) 0) (propertize "✗" 'face 'roost-status-failed))
                                        ((> (nth 2 counts) 0) (propertize "…" 'face 'roost-dim))
                                        (t (propertize "✓" 'face 'roost-status-ready))))
                                (pcase review
                                  ("APPROVED" (propertize "+" 'face 'roost-status-ready))
                                  ("CHANGES_REQUESTED" (propertize "!" 'face 'roost-status-permission)))
                                ;; Once merged, the commit counts no longer mean work to finish.
                                (unless open
                                  (propertize (symbol-name state) 'face (roost--pr-face state)))))))
        (string-join parts " "))
    ""))

(defun roost--insert-issue (task)
  "Insert TASK's \"Issue\" section when it was started from a GitHub issue."
  (when-let* ((issue (roost--field task 'issue))
              (number (alist-get 'number issue)))
    (roost--insert-heading "Issue")
    (insert "  ")
    (insert-text-button (format "#%s" number)
                        'follow-link t 'face 'roost-field
                        'help-echo (alist-get 'url issue)
                        'action (lambda (_) (browse-url (alist-get 'url issue))))
    (insert (format "  %s\n" (or (alist-get 'title issue) "")))))

(defun roost--insert-pull-request (task)
  "Insert TASK's \"Pull request\" section when it has a pull request."
  (when-let* ((pr (roost--field task 'pr))
              (state (roost--pr-state task)))
    (let* ((status (roost--field task 'prStatus))
           (counts (roost--pr-checks task))
           (review (alist-get 'review status)))
      (roost--insert-heading "Pull request")
      (insert "  ")
      (insert-text-button (format "#%s" (alist-get 'number pr))
                          'follow-link t 'face 'roost-field
                          'help-echo (alist-get 'url pr)
                          'action (lambda (_) (browse-url (alist-get 'url pr))))
      (insert (propertize (format "  %s\n" (alist-get 'url pr)) 'face 'roost-dim))
      (roost--insert-indented
       (string-join
        (delq nil
              (list (propertize (pcase state ('draft "Draft") ('merged "Merged") ('closed "Closed")
                                  (_ "Open"))
                                'face (roost--pr-face state))
                    (when (and counts (memq state '(open draft)))
                      (string-join
                       (delq nil (list (when (> (nth 1 counts) 0) (format "%d failing" (nth 1 counts)))
                                       (when (> (nth 2 counts) 0) (format "%d pending" (nth 2 counts)))
                                       (when (> (nth 0 counts) 0) (format "%d passing" (nth 0 counts)))))
                       ", "))
                    (when (and review (memq state '(open draft)))
                      (pcase review ("APPROVED" "approved") ("CHANGES_REQUESTED" "changes requested")
                        ("REVIEW_REQUIRED" "review required")))))
        " · "))
      (when (eq state 'merged)
        (roost--insert-indented
         (if (roost--landed task)
             (substitute-command-keys
              "Merged on GitHub. \\<roost-task-info-mode-map>\\[roost-retire] retires this task, removing its worktree and branch.")
           "Merged on GitHub, but not the commits since.")
         'roost-dim)))))

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
Magit to commit it."
  (interactive)
  (setq task (roost--choose task))
  (let* ((name (roost--field task 'name))
         (offer (lambda ()
                  (when (y-or-n-p
                         (substitute-command-keys
                          (format "%s has work not merged into %s (%s).  Discard it? "
                                  name (or (roost--field task 'integrationBranch) "its branch")
                                  ;; m merges only committed work.
                                  (if (roost--field task 'dirty)
                                      "\\<roost-task-info-mode-map>\\[roost-review] commits it in Magit"
                                    "\\<roost-task-info-mode-map>\\[roost-merge-retire] merges it"))))
                    (roost-discard task))))
         (retire (lambda ()
                   (roost--act task "retire" nil
                               (lambda (retired)
                                 (roost--retired-workspace retired)
                                 (roost--kill-worktree-buffers retired)
                                 (message "Retired %s, and removed its worktree and branch" name))
                               (lambda (err)
                                 ;; Git statistics newer than Roost's.
                                 (if (string-match-p "\\`\\(Task branch has unmerged\\|Uncommitted or untracked\\)" err)
                                     (funcall offer)
                                   (message "Roost %s: %s" (roost--host-label (roost--field task 'host)) err)))))))
    (cond
     ((member (roost--field task 'status) '("starting" "running" "permission" "background"))
      (user-error "%s's agent is at work; stop it (K) first, or wait" name))
     ((roost--unmerged-work-p task)
      (funcall offer))
     ((y-or-n-p (format "Retire %s, removing its worktree and branch?  Nothing in them would be lost. " name))
      (funcall retire)))))

;;;###autoload
(defun roost-merge-retire (&optional task)
  "Merge TASK's committed work into its recorded integration branch and retire.
Dirty worktrees are refused; review and commit in Magit first.  The work
comes in as one squashed commit, or a merge commit; see `roost-merge-style'."
  (interactive)
  (setq task (roost--choose task))
  (cond
   ;; The host refuses a dirty worktree; say so rather than ask to merge.
   ((roost--field task 'dirty)
    (when (y-or-n-p (format "%s has uncommitted changes to commit first.  Open Magit? "
                            (roost--field task 'name)))
      (roost-review task)))
   ((y-or-n-p (format (if (eq roost-merge-style 'squash)
                             "Squash committed work from %s into one commit and retire it? "
                           "Merge committed work from %s and retire it? ")
                         (roost--field task 'name)))
    (roost--act task "merge" (when (eq roost-merge-style 'squash) '((style . "squash")))
                (lambda (merged)
                  (roost--retired-workspace merged)
                  (roost--kill-worktree-buffers merged)
                  ;; The other tasks are measured against the branch that moved.
                  (roost--refresh-host (roost--field merged 'host) nil)
                  (message (if (eq roost-merge-style 'squash)
                               "Squashed %s into %s, and removed its worktree and branch"
                             "Merged %s into %s, and removed its worktree and branch")
                           (roost--field task 'name)
                           (or (roost--field task 'integrationBranch) "its branch")))))))

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
    (when (yes-or-no-p (format (if running
                                   "Stop %s's agent and forget the task, leaving its worktree and branch as they are? "
                                 "Forget %s, leaving its worktree and branch as they are? ")
                               name))
      (if running
          (roost--act task "stop" nil forget)
        (funcall forget)))))

;;;###autoload
(defun roost-discard (&optional task)
  "Delete TASK's worktree, branch and window, and drop it from Roost.
First says what would be lost, commits no other branch holds and files
not committed, here and in worktrees its agent made, which go too; to
lose any, you type the task's name.  For an experiment you don't want;
finished work is merged or retired instead."
  (interactive)
  (setq task (roost--choose task))
  (let* ((name (roost--field task 'name))
         (told (alist-get 'discard
                          (roost--request-wait (roost--field task 'host) "discard"
                                               (list (cons 'id (roost--field task 'id))
                                                     (cons 'dryRun t)))))
         (commits (or (alist-get 'commits told) 0))
         (changes (or (alist-get 'changes told) 0))
         (worktrees (or (alist-get 'agentWorktrees told) 0))
         (losses (delq nil (list (when (> commits 0)
                                   (format "%d commit%s no other branch has"
                                           commits (if (= commits 1) "" "s")))
                                 (when (> changes 0)
                                   (format "%d uncommitted file%s"
                                           changes (if (= changes 1) "" "s"))))))
         (label (if (> worktrees 0)
                    (format "%s, with %d worktree%s its agent made,"
                            name worktrees (if (= worktrees 1) "" "s"))
                  name)))
    (if (not (if losses
                 (equal (string-trim
                         (read-string (format "Discarding %s loses %s%s.  Type its name to discard it: "
                                              label (string-join losses " and ")
                                              (if (roost--agent-running-p task) ", and stops its agent" ""))))
                        name)
               (y-or-n-p (format "Discard %s, %sdeleting its worktree and branch?  Nothing in them would be lost. "
                                 label (if (roost--agent-running-p task) "stopping its agent and " "")))))
        (message "%s was not discarded" name)
      (roost--act task "discard" (list (cons 'expect (alist-get 'commit told)))
                  (lambda (discarded)
                    (roost--retired-workspace discarded)
                    (roost--kill-worktree-buffers discarded)
                    (message "Discarded %s" name))))))

(defun roost--kill-worktree-buffers (task)
  "Kill the Magit and Dired buffers left in TASK's removed worktree.
File buffers stay, since they may hold unsaved edits."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'magit-mode 'dired-mode)
                 (roost--task-in-directory default-directory (list task)))
        (kill-buffer buffer)))))

(defun roost--retired-workspace (task)
  "Remove TASK's workspace and panel, retaining other buffers.
A window made to show the panel goes away; any other goes back to what
it showed before."
  (let ((key (roost--key task)))
    (dolist (buffer (buffer-list))
      (when (and (equal (buffer-local-value 'roost--buffer-task-key buffer) key)
                 (eq (buffer-local-value 'major-mode buffer) 'roost-task-info-mode))
        ;; In every frame.  Before Emacs 31 this kills only a panel that
        ;; shows, so kill the rest too.
        (quit-windows-on buffer t)
        (when (buffer-live-p buffer) (kill-buffer buffer)))))
  (pcase (roost--workspace-backend)
    ('perspective
     (when (fboundp 'persp-kill)
       (let ((persp-autokill-buffer-on-remove nil))
         (persp-kill (roost--perspective-name task))))
     (remhash (roost--key task) roost--perspectives))
    ('tab-bar
     (let ((name (roost--task-tab task)))
       (when (and name (cdr (roost--tabs)))
         (tab-bar-close-tab-by-name name))))))

;;;###autoload
(defun roost-next-waiting ()
  "Open the next task whose agent is waiting for you.
Permission requests and agents stuck at a startup prompt come first,
since they block their agent; then tasks ready for a prompt, and those
that failed, crashed or exited, in turn."
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
         (key (if (and blocked (not (equal blocked (list viewing))))
                  ;; In turn from the one you are looking at, if blocked.
                  (or (cadr (member viewing blocked))
                      (seq-find (lambda (key) (not (equal key viewing))) blocked))
                (or (cadr (member (or viewing roost--current-task) keys)) (car keys)))))
    (unless key (user-error "No tasks are waiting for you"))
    (roost-open-task (gethash key roost--tasks) t)))

(defun roost--project-name (task)
  "Short primary repository name for TASK."
  (file-name-nondirectory (directory-file-name (or (roost--field task 'repo) "unknown"))))

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
neither works nor has anything new for you."
  (cond ((gethash (roost--field task 'host) roost--errors) "offline")
        ((roost--merged-p task) "merged")
        (t (roost--status-name task))))

(defun roost--merged-p (task)
  "Whether TASK's work is merged, as its host last measured, and nothing needs you.
Its commits are in its integration branch or a pull request GitHub
merged, nothing is left uncommitted, and its agent is not at work, did
not fail, and has said nothing you haven't seen."
  (and (eq (roost--landed task t) t)
       (not (roost--field task 'dirty))
       (not (roost--field task 'merging))
       (not (roost--field task 'worktreeMissing))
       (not (roost--agent-work-left task))
       (not (member (roost--field task 'status)
                    '("starting" "running" "permission" "background" "failed" "crashed")))
       ;; Stopped too: its host keeps it seen only if it was before.
       (roost--seen-p task)))

(defun roost--status-face (status)
  "Face for STATUS."
  (pcase status
    ((or "permission" "prompt") 'roost-status-permission)
    ((or "ready" "interrupted") 'roost-status-ready)
    ((or "running" "background") 'roost-status-running)
    ((or "failed" "crashed" "error") 'roost-status-failed)
    ("merged" 'roost-pr-merged)
    (_ 'roost-status-inactive)))

(defun roost--status-word-face (status)
  "Face for STATUS, from `roost--attention-status', written beside its dot.
The dot has the status's colour.  The word has it too when the agent
can't go on without you or failed, or the task is merged, is plain
while the agent waits for you otherwise, and is dim the rest of the time."
  (pcase status
    ((or "permission" "prompt" "error" "failed" "crashed" "merged") (roost--status-face status))
    ((or "ready" "interrupted") nil)
    (_ 'roost-dim)))

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
  "Whether the status lights of agents waiting for you move.
One asking you something pulses, and one that finished, failed, crashed
or exited since you saw it glows slowly; the rest stay still, so motion
always means an agent needs you.
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

(defconst roost--light-periods '((pulse . 1.6) (glow . 3.4))
  "Seconds each motion of a status light takes.")

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
Only an agent waiting for you moves, as `roost--waiting-p' has it: one
that can't go on without you pulses, and the others glow."
  (cond ((roost--blocked-p task) 'pulse)
        ((roost--waiting-p task) 'glow)))

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
A disc, smoothed at its edge, and while moving a halo that swells and
fades.  Canvases have no transparency, so it paints its background too.
Plain arithmetic, cheap even when Roost runs uncompiled."
  (let* ((image (plist-get light :image))
         (pixels (plist-get (cdr image) :data))
         (width (plist-get (cdr image) :data-width))
         (height (plist-get (cdr image) :data-height))
         (shape (roost--light-shape width height))
         (color (plist-get light :color))
         (background (plist-get light :background))
         (motion (plist-get light :motion))
         (wave (- 0.5 (* 0.5 (cos (* 2 float-pi phase)))))
         (radius (min 3.5 (- (/ (min width height) 2.0) 1)))
         (halo (pcase motion ('pulse (* 0.5 wave)) ('glow (* 0.25 wave)) (_ 0)))
         (reach (+ radius (if (eq motion 'pulse) (+ 1.5 (* 2.5 wave)) 2.5)))
         (edge (+ radius 0.5))
         (br (logand (ash background -16) 255)) (bg (logand (ash background -8) 255)) (bb (logand background 255))
         (dr (- (logand (ash color -16) 255) br)) (dg (- (logand (ash color -8) 255) bg)) (db (- (logand color 255) bb))
         (kr (logand (ash color -16) 255)) (kg (logand (ash color -8) 255)) (kb (logand color 255))
         (span (- reach radius)))
    (fillarray pixels background)
    (dotimes (i (length pixels))
      (let ((d (aref shape i)))
        (when (< d (max reach edge))
          (let* ((glow (if (and (> halo 0) (< d reach)) (* halo (expt (/ (- reach d) span) 2)) 0))
                 (cover (max 0.0 (min 1.0 (- edge d))))
                 (r (+ br (* glow dr))) (g (+ bg (* glow dg))) (b (+ bb (* glow db))))
            (aset pixels i (logior #xFF000000
                                   (ash (round (+ r (* cover (- kr r)))) 16)
                                   (ash (round (+ g (* cover (- kg g)))) 8)
                                   (round (+ b (* cover (- kb b))))))))))
    (when (fboundp 'canvas-refresh)
      (canvas-refresh image 'reload-data))))

(defconst roost--light-steps 16
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

(defun roost--status-light (task place &optional inline)
  "TASK's status dot at PLACE: a moving light when `roost--animations-p'.
The light shows in the window's left margin, which no highlight covers,
and takes no column of the text; with INLINE, it shows in place of the
dot.  Otherwise this is the dot, in TASK's status face."
  (let* ((status (roost--attention-status task))
         (face (roost--status-face status)))
    (if (not (roost--animations-p))
        (propertize "●" 'face face)
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
COMPACT abbreviates commits ahead of and behind the integration branch.
LISTED non-nil leaves out whether changes are uncommitted, for where
the files are listed under labels that say so."
  (let* ((diff (or (roost--field task 'diff) ""))
         (count (lambda (pattern)
                  (if (string-match (concat "\\([0-9]+\\) " pattern) diff)
                      (string-to-number (match-string 1 diff))
                    0)))
         (files (funcall count "files? changed"))
         ;; Git's statistics leave out files it does not track yet.
         (new (seq-count (lambda (file) (alist-get 'untracked file)) (roost--field task 'files)))
         (ahead (or (roost--field task 'ahead) 0))
         (behind (or (roost--field task 'behind) 0))
         (commits (delq nil (list (when (> ahead 0) (format (if compact "↑%d" "%d ahead") ahead))
                                  (when (> behind 0) (format (if compact "↓%d" "%d behind") behind))))))
    (string-join
     (delq nil (list (when (> files 0)
                       (format "%d file%s +%d −%d" files (if (= files 1) "" "s")
                               (funcall count "insertions?") (funcall count "deletions?")))
                     (when (> new 0)
                       (if (> files 0) (format "%d new" new)
                         (format "%d new file%s" new (if (= new 1) "" "s"))))
                     (when (and (roost--field task 'dirty) (not listed)) "uncommitted")
                     (when commits (string-join commits (if compact " " " · ")))))
     " · ")))

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
        (dolist (file (seq-take group room))
          (roost--insert-changed-file task file width))
        (setq room (max 0 (- room (length group))))))
    (when (length> files roost--changed-files-shown)
      (roost--insert-indented
       (substitute-command-keys
        (format "and %d more; \\<roost-task-info-mode-map>\\[roost-diff] shows every change"
                (- (length files) roost--changed-files-shown)))
       'roost-dim))))

(defun roost--insert-changed-file (task file width)
  "Insert a button showing FILE, one of TASK's `files', within WIDTH columns."
  (let* ((path (alist-get 'path file))
         (counts (cond ((alist-get 'untracked file) (propertize "new" 'face 'roost-diff-added))
                       ((alist-get 'added file)
                        (roost--fontify-changes (format "+%d −%d" (alist-get 'added file)
                                                        (alist-get 'deleted file))))
                       (t (propertize "binary" 'face 'roost-dim))))
         (room (max 8 (- width 6 (string-width counts)))))
    (insert "  ")
    ;; Long paths keep their end, which names the file.
    (insert-text-button (if (> (string-width path) room)
                            (concat "…" (truncate-string-to-width
                                         path (string-width path)
                                         (- (string-width path) (1- room))))
                          path)
                        'follow-link t 'face 'roost-field
                        'help-echo (concat path "\nmouse-1: show its changes")
                        'action (lambda (_) (roost--diff-file task file)))
    (insert "  " counts "\n")))

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

(defun roost--diff-file (task file)
  "Show how TASK has changed FILE, an entry of its `files'.
An untracked file, with nothing to compare, is opened instead."
  (roost--activate-workspace task)
  (let ((default-directory (roost--remote-directory task))
        (path (alist-get 'path file)))
    (if (and (not (alist-get 'untracked file)) (require 'magit nil t))
        (progn (roost--magit-setup)
               (magit-diff-working-tree (roost--fork-point task) nil (list path)))
      (find-file (expand-file-name path)))))

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
  (setq header-line-format
        (format " %s: %s · %s retries" what
                (or (car (split-string err "\n" t "[ \t]+")) err)
                (substitute-command-keys (format "\\[%s]" command)))))

(defun roost--one-line (string)
  "STRING with line breaks and tabs collapsed, for a table cell."
  (string-trim (replace-regexp-in-string "[\n\r\t]+" " " (or string ""))))

(defun roost--prompt-text (task)
  "TASK's prompt, or nil when it was created without one."
  (let ((prompt (roost--field task 'task)))
    (unless (or (null prompt) (equal prompt (roost--field task 'name))) prompt)))

(defconst roost--url-regexp
  "\\([*_~]*\\)\\(https?://[^[:space:]<>\"'`\ue000\ue001]+\\)"
  "A URL in what an agent wrote, with the Markdown emphasis that opens on it
and anything that follows it up to a space.")

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
                      'roost-note-box-mode)
    (display-line-numbers-mode -1)
    (when (derived-mode-p 'roost-dashboard-mode 'roost-search-mode)
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
    ["Update from integration branch" roost-update :active (roost--menu-applies-p 'roost-update)]
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
    ["Rename…" roost-rename :active (roost--menu-applies-p 'roost-rename)])
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
                      (roost--display-status task))
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
                   roost-diff roost-update roost-pr roost-merge-retire roost-retire roost-forget
                   roost-stop roost-resume roost-goto-note roost-rename))
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
      ((or 'roost-files 'roost-review 'roost-diff 'roost-update) worktree)
      ((or 'roost-send 'roost-stop) (roost--agent-running-p task))
      ('roost-resume (and worktree (not (roost--agent-running-p task))))
      ('roost-pr (and worktree (or (roost--field task 'pr) (not (eql ahead 0)))))
      ('roost-merge-retire (and (not merged) (not (eql ahead 0)) (not active)
                                (not (roost--agent-work-left task))))
      ;; Retires the task, or discards work merged nowhere.
      ('roost-retire (and (not active) (not (roost--agent-work-left task))))
      ('roost-goto-note (and worktree (roost--task-notes task) t))
      (_ t))))

(defun roost--next-step (task &optional menu)
  "What to do next with TASK, as a line naming its key, or nil.
MENU non-nil means the line is for `roost-dispatch', away from the
task panel's list of the agent's own worktrees."
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
      (concat "Answer it in its terminal: " (funcall key "RET")))
     ((equal status "prompt")
      (concat "It may be waiting at a startup prompt, such as folder trust: " (funcall key "RET")))
     ((roost--field task 'worktreeMissing)
      (concat "Its worktree is gone: " (funcall key "x") " retires it if its work is merged, "
              (funcall key "X") " forgets it"))
     ;; Whether its agent is still there or not.
     ((equal status "merged") (funcall retire))
     ((equal status "error")
      (concat "Its last turn failed; open it to try its last prompt again: " (funcall key "RET")))
     ((member status '("stopped" "crashed"))
      (concat (funcall key "RET") " or " (funcall key "s") " resumes its conversation"))
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
     ;; As for one you haven't looked at since its agent finished.
     ((roost--landed task) (funcall retire))
     (merged (concat "Its pull request is merged, but not its commits since: " (funcall key "m") " merges them"))
     ((memq state '(open draft))
      (concat (funcall key "P") " pushes new commits to its pull request"))
     ((and (numberp (roost--field task 'ahead)) (> (roost--field task 'ahead) 0))
      (concat (funcall key "m") " merges it, or " (funcall key "P") " opens a pull request")))))

;;;###autoload (autoload 'roost-dispatch "roost" nil t)
(transient-define-prefix roost-dispatch ()
  "Show Roost's commands.
Task commands act on the task at point, in the dashboard, a task panel,
terminal or worktree, or ask which task."
  [:description roost--dispatch-task-description
   ["Work"
    ("RET" "Agent" roost-open-task :inapt-if roost--open-task-inapt-p)
    ("t" "Shell" roost-shell :inapt-if roost--shell-inapt-p)
    ("f" "Files" roost-files :inapt-if roost--files-inapt-p)
    ("e" "Send prompt" roost-send :inapt-if roost--send-inapt-p)
    ("i" "Details" roost-task-info :inapt-if roost--task-info-inapt-p)
    ("R" "Rename" roost-rename :inapt-if roost--rename-inapt-p)]
   ["Review"
    ("r" "Magit" roost-review :inapt-if roost--review-inapt-p)
    ("D" "Diff" roost-diff :inapt-if roost--diff-inapt-p)
    ("u" "Update from integration" roost-update :inapt-if roost--update-inapt-p)
    ("'" "Go to note" roost-goto-note :inapt-if roost--goto-note-inapt-p)]
   ["Finish"
    ("P" "Pull request" roost-pr :inapt-if roost--pr-inapt-p)
    ("m" "Merge and retire" roost-merge-retire :inapt-if roost--merge-retire-inapt-p)
    ("x" "Retire or discard" roost-retire :inapt-if roost--retire-inapt-p)
    ("X" "Forget" roost-forget :inapt-if roost--forget-inapt-p)]
   ["Session"
    ("K" "Stop" roost-stop :inapt-if roost--stop-inapt-p)
    ("s" "Resume" roost-resume :inapt-if roost--resume-inapt-p)]]
  ["Roost"
   [("c" "New task" roost-new-task)
    ("n" "Next waiting" roost-next-waiting)
    ("l" "Switch task" roost-switch-task)
    ("/" "Search sessions" roost-search)]
   [("S" "Dashboard" roost-status)
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
  "I" #'roost-task-panel-mode
  ;; Commands beyond this task, as in the dashboard and sidebar.
  "n" #'roost-next-waiting
  "l" #'roost-switch-task
  "/" #'roost-search
  "c" #'roost-new-task
  "b" #'roost-sidebar-mode
  "S" #'roost-status
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

(defun roost--panel-beside-terminal-p (task)
  "Whether each window showing this task panel has TASK's terminal in its frame.
Then the panel leaves the agent's conversation to the terminal; one
window without it, such as in another frame, keeps the conversation."
  (when-let* ((windows (get-buffer-window-list nil 'nomini 'visible)))
    (seq-every-p (lambda (window)
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
                  ((not (eq (not roost--beside-terminal)
                            (not (roost--panel-beside-terminal-p task))))))
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

(defun roost--insert-heading (title)
  "Insert section TITLE."
  (insert roost--gap (propertize title 'face 'roost-heading) "\n"))

(defvar-local roost--show-full-prompt nil
  "Non-nil when the task panel shows a long prompt in full.")

(defvar-local roost--expanded-reply nil
  "The reply expanded in a compact panel, or nil.
A different reply starts collapsed when it arrives.")

(defun roost--reply-preview (reply width)
  "The first six lines of REPLY as shown wrapped in WIDTH columns.
Return short replies unchanged.  Faces in REPLY, as from `roost--prose',
count in its width."
  (let* ((columns (max 12 (- width 2)))
         (lines (roost--wrap-width reply columns 6)))
    (if (<= (length lines) 6)
        reply
      (let ((last (string-trim-right (nth 5 lines))))
        (concat (string-join (seq-take lines 5) "\n") "\n"
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

(defun roost--insert-indented (text &optional face)
  "Insert TEXT wrapped and indented under a heading, adding FACE."
  (let ((text (propertize (concat text "\n") 'line-prefix "  " 'wrap-prefix "  ")))
    (when face (add-face-text-property 0 (length text) face t text))
    (insert text)))

(defun roost--insert-toggle (label what action)
  "Insert a button LABEL on a line of its own that calls ACTION and redraws.
WHAT names what it shows or hides, as `prompt': once redrawn, point is on
the button for WHAT, so that pressing it again takes the change back."
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
    (put-text-property start (point) 'line-prefix "  ")))

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
      (let* ((status (roost--display-status task))
             (changes (roost--changes task nil (roost--field task 'files)))
             (width (roost--task-info-width))
             (base (roost--field task 'baseRef))
             (integration (roost--field task 'integrationBranch))
             ;; With the agent's terminal on screen, the conversation is its.
             (beside (setq roost--beside-terminal (roost--panel-beside-terminal-p task))))
        (let ((name (propertize (roost--field task 'name) 'face 'roost-title))
              (state (concat (roost--status-light task (cons 'panel (current-buffer)) t)
                             (propertize (concat " " status)
                                         'face (roost--status-word-face (roost--attention-status task)))
                             ;; Not since it merged, but since its agent last moved.
                             (unless (equal status "merged")
                               (propertize (format " for %s" (roost--elapsed (roost--field task 'updatedAt)))
                                           'face 'roost-dim)))))
          ;; The status keeps to one line, below the name when both don't fit.
          (insert name (if (> (+ (roost--text-width name) 3 (roost--text-width state)) width) "\n" "   ")
                  state "\n"))
        (insert (propertize (format "%s · %s · %s" (roost--host-label (roost--field task 'host))
                                    (roost--project-name task)
                                    (or (roost--field task 'agent) "claude"))
                            'face 'roost-dim)
                "\n")
        (when-let* ((next (roost--next-step task)))
          (insert roost--gap next "\n"))
        (unless beside
          (when-let* ((request (roost--permission-request task)))
            (roost--insert-heading "Waiting for your answer")
            (roost--insert-indented (roost--prose request))))
        (when-let* ((prompt (roost--prompt-text task)))
          (roost--insert-heading "Prompt")
          (let ((preview (roost--prompt-preview prompt)))
            (cond ((equal preview prompt)
                   (roost--insert-indented (roost--prose prompt)))
                  (roost--show-full-prompt
                   (roost--insert-toggle "Collapse prompt" 'prompt
                                         (lambda () (setq roost--show-full-prompt nil)))
                   (roost--insert-indented (roost--prose prompt)))
                  (t
                   (roost--insert-indented (roost--prose preview))
                   (roost--insert-toggle "Show the whole prompt" 'prompt
                                         (lambda () (setq roost--show-full-prompt t)))))))
        (when-let* (((not beside))
                    (reply (roost--last-message task))
                    (reply (roost--prose reply)))
          (roost--insert-heading "Agent's latest reply")
          (let* ((preview (if (< width 72) (roost--reply-preview reply width) reply))
                 (expanded (equal reply roost--expanded-reply)))
            (unless expanded (setq roost--expanded-reply nil))
            (when (and expanded (not (equal preview reply)))
              (roost--insert-reply-toggle reply t))
            (roost--insert-indented (if expanded reply preview))
            (when (and (not expanded) (not (equal preview reply)))
              (roost--insert-reply-toggle reply nil))))
        (roost--insert-heading "Changes")
        (roost--insert-indented
         (cond ((roost--field task 'worktreeMissing)
                (propertize "The worktree is gone"
                            'face 'roost-status-failed))
               ((not (assq 'diff task)) (propertize "Refreshing…" 'face 'roost-dim))
               ((string-empty-p changes) (propertize "No changes yet" 'face 'roost-dim))
               (t (roost--fontify-changes changes))))
        (roost--insert-changed-files task width)
        (if-let* ((notes (roost--notes-summary task)))
            (roost--insert-indented notes)
          (when (and (fboundp 'magit-status)
                     (seq-some (lambda (file) (not (alist-get 'untracked file)))
                               (roost--field task 'files)))
            (roost--insert-indented
             (concat "In a file's diff, "
                     (substitute-command-keys "\\<roost-magit-mode-map>\\[roost-note]")
                     " writes a note for the agent")
             'roost-dim)))
        (if-let* ((merging (roost--field task 'merging)))
            (roost--insert-indented
             (substitute-command-keys
              (if-let* ((conflicts (alist-get 'conflicts merging)))
                  (format "Merging %s into it conflicts in %s: resolve them and commit in Magit (\\<roost-task-info-mode-map>\\[roost-review]), or ask its agent to (\\[roost-send])."
                          integration (string-join conflicts ", "))
                (format "A merge of %s is under way in it: commit it in Magit (\\<roost-task-info-mode-map>\\[roost-review])."
                        integration)))
             'roost-status-permission)
          ;; Not when it moved on by merging the task.
          (when (and (> (or (roost--field task 'behind) 0) 0) (not (eq (roost--landed task t) t)))
            (roost--insert-indented
           (substitute-command-keys
            (format "%s has moved on; \\<roost-task-info-mode-map>\\[roost-update] merges it into this task before you merge the task back."
                    integration))
           'roost-dim)))
        (roost--insert-agent-work task)
        ;; How an agent ended, or why it waits, is the next step's, above.
        (pcase status
          ("offline"
           (roost--insert-indented "The host is unreachable; this is the last known state." 'roost-dim))
          ("starting"
           (when (equal (roost--field task 'agent) "codex")
             (roost--insert-indented
              "Codex reports status from its first turn. Open the terminal, review any hook or startup prompts, and enter the first prompt there; sending prompts from Emacs works after that."
              'roost-dim))))
        (when-let* ((error (roost--field task 'error)))
          (roost--insert-indented (concat "Last error: " error) 'roost-status-failed))
        (roost--insert-issue task)
        (roost--insert-pull-request task)
        (roost--insert-heading "Details")
        (dolist (entry `(("Branch" . ,(format "%s, from %s%s" (roost--field task 'branch) base
                                              (if (and integration (not (string-empty-p integration)))
                                                  (format ", merges into %s" integration)
                                                "")))
                         ,@(unless (< width 72)
                             `(("Worktree" . ,(roost--abbreviate-path (or (roost--field task 'worktree) "")
                                                                      (roost--field task 'host)))
                               ("Project" . ,(roost--abbreviate-path (or (roost--field task 'repo) "")
                                                                     (roost--field task 'host)))
                               ("Tmux" . ,(format "session %s on socket %s" (roost--field task 'session)
                                                  (roost--field task 'socket)))
                               ("Conversation" . ,(or (roost--field task 'agentSession)
                                                      (roost--field task 'claudeSession)
                                                      "not recorded yet"))))))
          (if (< width 72)
              ;; Too narrow for a label column: the value goes below its label.
              (insert "  " (propertize (car entry) 'face 'roost-dim) "\n"
                      (propertize (concat (or (cdr entry) "unknown") "\n")
                                  'line-prefix "  " 'wrap-prefix "  "))
            (insert (propertize (concat "  " (propertize (format "%-13s" (car entry)) 'face 'roost-dim)
                                        (or (cdr entry) "unknown") "\n")
                                'wrap-prefix (make-string 15 ?\s)))))
        (insert roost--gap
                (propertize (substitute-command-keys
                             (concat (unless (< width 72)
                                       "Ready means the agent is waiting for you, not that the work is reviewed.\n")
                                     "\\<roost-task-info-mode-map>\\[roost-dispatch] opens the menu · "
                                     (unless (< width 72) "\\[roost-task-info-refresh] refreshes · ")
                                     "\\[roost-task-info-quit] closes"))
                            'face 'roost-dim)
                "\n")))
    (goto-char (min position (point-max)))
    (roost--restore-mark mark)
    (roost--restore-window-places places)
    ;; Redrawing removed the highlight with the text.
    (roost--mark-selection)))

(defun roost--task-label (task)
  "TASK's name, qualified by host when names collide.
Tasks with the same name on the same host are told apart by their IDs."
  (let* ((name (roost--field task 'name))
         (host (roost--field task 'host))
         (twins (seq-filter (lambda (other) (equal (roost--field other 'name) name))
                            (roost-tasks))))
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
  "Show TASK's next step, prompt, the agent's latest reply, changes and details."
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
  "r" #'roost-review
  "D" #'roost-diff
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
  "n" #'roost-next-waiting
  "/" #'roost-search
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

(define-derived-mode roost-dashboard-mode special-mode "Roost"
  "Coding agent tasks across hosts, grouped by project.
Refreshes are asynchronous; rendering uses only cached state.
\\{roost-dashboard-mode-map}"
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
                          (sort (cdr group)
                                (lambda (a b) (string< (or (roost--field a 'startedAt) "")
                                                       (or (roost--field b 'startedAt) ""))))))
                  groups)
          (lambda (a b)
            (string< (format "%s %s" (roost--host-label (caar a)) (cadar a))
                     (format "%s %s" (roost--host-label (caar b)) (cadar b)))))))

(defun roost--summary (tasks)
  "One-line count of TASKS by status class."
  (let ((counts (make-hash-table :test 'equal)))
    (dolist (task tasks)
      (cl-incf (gethash (roost--attention-status task) counts 0)))
    (string-join
     (delq nil
           (mapcar (lambda (class)
                     (let ((count (apply #'+ (mapcar (lambda (status) (gethash status counts 0))
                                                     (cddr class)))))
                       (when (> count 0)
                         (propertize (format "%d %s" count (car class))
                                     'face (roost--status-word-face (nth 2 class))))))
                   '(("awaiting permission" nil "permission")
                     ("at a startup prompt" nil "prompt")
                     ("ready" nil "ready")
                     ("interrupted" nil "interrupted")
                     ("seen" nil "idle")
                     ("merged" nil "merged")
                     ("failed" nil "error" "failed" "crashed")
                     ("running" nil "running" "background" "starting")
                     ("stopped" nil "stopped" "exited")
                     ("offline" nil "offline"))))
     (propertize " · " 'face 'roost-dim))))

(defun roost--row-name (task &optional width face)
  "TASK's name in FACE for its row under its project, cut to WIDTH columns.
When another task in the project has the same name, the start of its ID
follows, dim, as in `roost-open-task' and tab names; cutting the name to
fit keeps the ID."
  (let* ((name (roost--field task 'name))
         (id (roost--field task 'id))
         (twin (seq-some (lambda (other)
                           (and (equal (roost--field other 'name) name)
                                (not (equal (roost--field other 'id) id))
                                (equal (roost--field other 'host) (roost--field task 'host))
                                (equal (roost--field other 'repo) (roost--field task 'repo))))
                         (roost-tasks)))
         (suffix (if (and twin id) (concat " " (substring id 0 (min 6 (length id)))) "")))
    (concat (propertize (if width
                            (truncate-string-to-width name (max 1 (- width (length suffix)))
                                                      nil nil "…")
                          name)
                        'face face)
            (propertize suffix 'face 'roost-dim))))

(defun roost--dashboard-layout (tasks width)
  "Column widths for TASKS in a window WIDTH columns wide.
The changes column shrinks first, then the agent column is dropped."
  (let* ((name (min 28 (max 8 (apply #'max (mapcar (lambda (task) (string-width (roost--row-name task)))
                                                   tasks)))))
         (agent (> (length (delete-dups (mapcar (lambda (task) (or (roost--field task 'agent) "claude"))
                                                tasks)))
                   1))
         (widest (min 40 (apply #'max (mapcar (lambda (task) (string-width (roost--changes task t)))
                                             tasks))))
         (changes widest)
         (pr (apply #'max (mapcar (lambda (task) (string-width (roost--pr-marker task))) tasks)))
         ;; Bullet, name, status, since and their separators.
         (fixed (+ 4 name 2 11 1 6 2 (if (> pr 0) (+ pr 2) 0)))
         (over (- (+ fixed (if agent 8 0) (if (> changes 0) (+ changes 2) 0)) width)))
    (when (> over 0)
      (setq changes (max 0 (- changes over)))
      (when (and agent (< changes 12))
        (setq agent nil changes (min widest (max 0 (- width fixed 2))))))
    (when (< changes 6) (setq changes 0))
    (list :name name :agent agent :changes changes :pr pr)))

(defun roost--dashboard-row (task layout width)
  "Dashboard line for TASK using column LAYOUT, fitting WIDTH columns."
  (let* ((status (roost--display-status task))
         (face (roost--status-word-face (roost--attention-status task)))
         (cell (lambda (text size &optional cell-face)
                 (propertize (truncate-string-to-width text size nil ?\s "…") 'face cell-face)))
         (name (roost--row-name task (plist-get layout :name)))
         (line (concat "  " (roost--status-light task 'dashboard) " "
                       name (make-string (max 0 (- (plist-get layout :name) (string-width name))) ?\s)
                       "  "
                       (funcall cell status 11 face) " "
                       (funcall cell (roost--elapsed (roost--field task 'updatedAt)) 6 'roost-dim) "  "
                       (if (> (plist-get layout :pr) 0)
                           (concat (truncate-string-to-width (roost--pr-marker task) (plist-get layout :pr)
                                                             nil ?\s "…")
                                   "  ")
                         "")
                       (if (plist-get layout :agent)
                           (concat (funcall cell (or (roost--field task 'agent) "claude") 6 'roost-dim) "  ")
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
                           (roost--one-line (or (roost--permission-request task)
                                                (roost--last-message-summary task)
                                                (roost--prompt-text task)))
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
            "     in the draft, \\<roost-compose-mode-map>\\[roost-compose-set-issue] picks a GitHub issue.\n"
            "  \\<roost-dashboard-mode-map>\\[roost-dispatch]  Every command.\n"
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
         (heading (unless key (get-text-property position 'roost-directory)))
         (mark (roost--mark-place))
         (start-line (when window (line-number-at-pos (window-start window))))
         ;; Without fringes, as in a terminal, a full line would lose its last
         ;; column to the truncation mark; this leaves room for it.
         (width (roost--narrowest-width 120))
         (tasks (roost-tasks))
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
              (insert roost--gap heading
                      (if (< room 4) ""
                        (propertize (concat "  " (roost--truncate-start
                                                  (roost--abbreviate-path (or repo "") host) room))
                                    'face 'roost-dim))
                      note "\n"))
            ;; `c' on the heading starts a task in this project.
            (when repo
              (put-text-property start (point) 'roost-directory
                                 (roost--project-directory (cadr group))))
            (dolist (task (cdr group))
              (let ((row (list 'roost-task (roost--key task) 'keymap roost--dashboard-row-map)))
                (insert (apply #'propertize (roost--dashboard-row task layout width)
                               'mouse-face 'highlight 'help-echo "mouse-1: open · mouse-3: actions" row)
                        ;; Without `mouse-face', so each row lights up alone,
                        ;; but still the task's, for point and clicks there.
                        (apply #'propertize "\n" row))))))))
    (let ((target (or (and key (roost--task-row key))
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
  "The task on the current dashboard line, if any."
  (when-let* ((key (get-text-property (line-beginning-position) 'roost-task)))
    (gethash key roost--tasks)))

(defun roost-dashboard-next-task (&optional count)
  "Move to the next task line, or COUNT lines of tasks."
  (interactive "p")
  (dotimes (_ (abs (or count 1)))
    (let ((step (if (< (or count 1) 0) -1 1)) (origin (point)))
      (forward-line step)
      (while (and (not (get-text-property (point) 'roost-task))
                  (zerop (forward-line step))))
      (unless (get-text-property (point) 'roost-task) (goto-char origin)))))

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
  ;; Data that just arrived can name the task a restored workspace shows.
  (when (memq #'roost--layout-changed (default-value 'window-configuration-change-hook))
    (roost--sync-side-windows))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-task-info-mode)
        (roost--render-visible #'roost--render-task-info)))))

;;;###autoload
(defun roost-status ()
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
  (interactive (list (read-string "Search sessions: " nil 'roost-search-history)))
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
    (insert (propertize "Messages containing " 'face 'roost-dim)
            (propertize roost--search-query 'face 'roost-heading) "\n")
    (when pending
      (insert (propertize (format "Searching %s…\n" (mapconcat #'roost--host-label pending ", "))
                          'face 'roost-dim)))
    (pcase-dolist (`(,host . ,reply) (reverse roost--search-replies))
      (cond ((eq (car-safe reply) :error)
             (insert (propertize (format "Could not search %s: %s\n" (roost--host-label host) (cadr reply))
                                 'face 'roost-status-failed)))
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
             (status (cond (task (roost--display-status task)) ((not key) "past task")))
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
  "S" #'roost-status
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
Entering it anywhere but on a task starts on the task you are working
on, or else the first.  Once in, point may also rest on a project's
heading, where `c' starts a task in that project; so may a click."
  (when-let* ((buffer (get-buffer roost--sidebar-buffer))
              (window (selected-window))
              ((eq (window-buffer window) buffer)))
    (with-current-buffer buffer
      (unless (or (mouse-event-p last-input-event)
                  (get-text-property (window-point window) 'roost-task))
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
      (propertize (format "%d waiting" waiting) 'face (roost--waiting-face tasks)))))

(defun roost--waiting-face (tasks)
  "Face for a count of TASKS waiting: as for the most urgent of them.
An agent asking, then one that failed, then one that finished."
  (cond ((seq-some #'roost--blocked-p tasks) 'roost-status-permission)
        ((seq-some (lambda (task)
                     (and (roost--waiting-p task)
                          (member (roost--attention-status task) '("error" "failed" "crashed"))))
                   tasks)
         'roost-status-failed)
        (t 'roost-status-ready)))

(defun roost--current-task-p (task)
  "Whether TASK is the one you are working on, which the sidebar marks."
  (if (roost--workspace-backend)
      (equal (roost--workspace-name task) (roost--current-workspace))
    (equal (roost--key task) roost--current-task)))

(defun roost--sidebar-row (task width)
  "TASK's sidebar line, within WIDTH columns: its name, then its status.
The status is in its colour when you have something to look at, dim
when there is only something to know, and not there for an agent you
have seen that waits for nothing."
  (let* ((current (roost--current-task-p task))
         (attention (roost--attention-status task))
         (face (if (roost--waiting-p task)
                   (roost--status-face attention)
                 (roost--status-word-face attention)))
         (urgent (and face (not (eq face 'roost-dim))))
         ;; After an indent.
         (room (1- width))
         (status (unless (equal attention "idle") (roost--display-status task)))
         ;; The fewest columns the name takes: one, and the ID that tells
         ;; it from a task of the same name.
         (least (string-width (roost--row-name task 1)))
         ;; A status you should look at shows even where the name then has
         ;; little room; the others, where its name keeps a dozen columns.
         (label (cond ((not status) nil)
                      ((>= room (+ (min (string-width (roost--row-name task)) 12) 1
                                   (string-width status)))
                       status)
                      (urgent (truncate-string-to-width status (max 1 (- room least 1)) nil nil "…"))))
         (name (roost--row-name task (if label (max 1 (- room (string-width label) 1)) room)
                                (if current 'roost-heading 'default))))
    (let ((row (concat " " name
                       (when label
                         (concat (make-string (max 1 (- room (string-width name) (string-width label))) ?\s)
                                 (propertize label 'face face))))))
      ;; Behind the row's own faces, so its status keeps its colour.
      (when current
        (add-face-text-property 0 (length row) 'roost-current t row))
      row)))

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
         (heading (unless key (get-text-property position 'roost-directory)))
         (tasks (roost-tasks))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Roost" 'face 'roost-title)
            (if-let* ((summary (roost--sidebar-summary tasks))) (concat "  " summary) "")
            ;; Nothing here changes until it watches again.
            (if roost-watch-mode "" (propertize "  paused" 'face 'roost-dim))
            "\n")
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
                               (file-name-nondirectory (directory-file-name (or repo "?"))))
                       (- width 2) nil nil "…")))
          (insert roost--gap (propertize label 'face (if (gethash host roost--errors)
                                                   'roost-status-failed 'roost-dim))
                  (make-string (max 1 (- width (string-width label) 1)) ?\s))
          (insert-text-button "+" 'face 'roost-key 'follow-link t
                              'help-echo (format "New task in %s" (or repo "this project"))
                              'action (lambda (button)
                                        (goto-char (button-start button))
                                        (call-interactively #'roost-new-task)))
          (insert "\n")
          ;; `c' on the heading starts a task in this project.
          (when repo
            (put-text-property start (point) 'roost-directory
                               (roost--project-directory (cadr group))))
          (dolist (task (cdr group))
            (let ((row (list 'roost-task (roost--key task) 'keymap roost--dashboard-row-map)))
              (insert (apply #'propertize (roost--sidebar-row task width)
                             'mouse-face 'highlight
                             'help-echo (format "%s\n%s · %s\nmouse-1: open · mouse-3: actions"
                                                (roost--field task 'name)
                                                (roost--host-label host)
                                                (or repo "?"))
                             row)
                      ;; As in the dashboard: unhighlighted, still the task's,
                      ;; and the current task's band reaches the window's edge.
                      (apply #'propertize "\n" (if (roost--current-task-p task)
                                                   (append '(face roost-current) row)
                                                 row))))))))
    (goto-char (or (and key (roost--task-row key))
                   (and heading (roost--heading-row heading))
                   (point-min)))
    (when window (set-window-point window (point)))
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
With workspaces, that is the task whose workspace is current; without,
the task last used in the frame, or taken up since; see
`roost--adopt-shown-task'."
  (if (roost--workspace-backend)
      (when-let* ((current (roost--current-workspace)))
        (seq-find (lambda (task) (equal (roost--workspace-name task) current))
                  (roost-tasks)))
    (gethash (frame-parameter nil 'roost-task) roost--tasks)))

(defun roost--adopt-shown-task ()
  "Take up the task whose terminal the selected frame shows, if its own is gone.
Once the task last used in the frame is gone, as when merged, Emacs shows
another buffer in its place, perhaps another task's terminal: the frame
takes that task up as if opened there, for its panel and the sidebar's
marker, and keeps it when a draft later covers the terminal.  Without
workspaces only, where the frame records its task."
  (unless (or (roost--workspace-backend)
              (gethash (frame-parameter nil 'roost-task) roost--tasks))
    ;; The terminal used last, though Magit or a file was used since.
    (when-let* ((task (seq-some (lambda (window) (roost--terminal-task (window-buffer window)))
                                (sort (roost--main-windows)
                                      (lambda (a b) (> (window-use-time a) (window-use-time b)))))))
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

(defun roost--sync-side-windows ()
  "Add or remove the selected frame's sidebar and task panel to match.
See `roost-sidebar-mode' and `roost-task-panel-mode'.  This only adds and
removes windows; their contents follow task updates, so a panel you have
scrolled stays where you left it."
  (when (roost--side-frame-p)
    (roost--adopt-shown-task)
    (let ((sidebar (get-buffer-window roost--sidebar-buffer)))
      (cond ((and roost-sidebar-mode (not sidebar)
                  (>= (frame-width) (+ roost-sidebar-width 80)))
             (roost--show-side-window (roost--sidebar-get-buffer) 'left roost-sidebar-width))
            ;; A saved workspace can bring back a sidebar after the mode is off.
            ((and sidebar (not roost-sidebar-mode))
             (dolist (window (get-buffer-window-list roost--sidebar-buffer))
               (when (window-parameter window 'window-side) (delete-window window))))))
    (let* ((panel (roost--task-panel-window))
           (task (and roost-task-panel-mode (roost--frame-task))))
      (cond ((not (and task (roost--task-panel-fits-p panel)))
             (when panel (delete-window panel)))
            ((and panel (equal (buffer-local-value 'roost--buffer-task-key (window-buffer panel))
                               (roost--key task))))
            (t
             (let ((buffer (roost--task-info-buffer task)))
               (roost--show-side-window buffer 'right roost-task-panel-width)
               ;; Lay it out for its window now rather than at the next resize.
               (with-current-buffer buffer (roost--render-task-info)))
             (unless (assq 'diff task)
               (roost--refresh-host (roost--field task 'host) nil)))))))

(defun roost--sync-all-frames ()
  "Apply `roost--sync-side-windows' to every frame."
  (dolist (frame (frame-list))
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
  "Keep a compact list of tasks at the left of every frame.
It stays when you switch perspectives or tabs and survives
\\[delete-other-windows].  Click a task, or press RET on it, to open it in
the main area; task commands such as `roost-review' act on the task at
point.  Turning the mode on starts `roost-watch-mode'.  Frames narrower
than `roost-sidebar-width' plus 80 columns go without."
  :global t
  (roost--watch-layout)
  (when roost-sidebar-mode (roost-watch-mode 1))
  (roost--sync-all-frames)
  (if roost-sidebar-mode
      (roost-refresh t)
    ;; In case the sidebar was selected.
    (roost--leave-side-window))
  (when (called-interactively-p 'any)
    (message (cond ((not roost-sidebar-mode)
                    (substitute-command-keys
                     "Sidebar off; \\<roost-dashboard-mode-map>\\[roost-sidebar-mode] in the dashboard turns it back on"))
                   ((get-buffer-window roost--sidebar-buffer) "Sidebar on")
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
  "Remove Roost's hooks, advice and side windows for `unload-feature'."
  (remove-hook 'tmux-control-switch-session-functions #'roost--switch-session)
  (when roost-sidebar-mode (roost-sidebar-mode -1))
  (dolist (frame (frame-list))
    (with-selected-frame frame
      (when-let* ((panel (roost--task-panel-window)))
        (delete-window panel))))
  (remove-hook 'window-configuration-change-hook #'roost--layout-changed)
  (remove-hook 'after-delete-frame-functions #'roost--frame-deleted)
  (when (timerp roost--layout-timer) (cancel-timer roost--layout-timer))
  (remove-hook 'magit-post-refresh-hook #'roost--magit-refreshed)
  (roost--magit-teardown)
  (when roost-watch-mode (roost-watch-mode -1))
  (when (timerp roost--lights-timer) (cancel-timer roost--lights-timer))
  (advice-remove 'persp-mode-line #'roost--compact-perspective-mode-line)
  ;; Continue with the standard unloading.
  nil)

;;;; Setup check

(defvar roost--doctor-results nil
  "Alist of (HOST . RESULT) for `roost-doctor'.
RESULT is `pending', a list of checks, or (error . MESSAGE).")

(defvar-keymap roost-doctor-mode-map
  :doc "Keys for the Roost setup check."
  "g" #'roost-doctor)

(define-derived-mode roost-doctor-mode special-mode "Roost Doctor"
  "What Roost needs locally and on each host, with fixes for problems.
\\{roost-doctor-mode-map}"
  (setq-local truncate-lines nil word-wrap t)
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

(defun roost--doctor-local-checks ()
  "List the local checks, each (NAME OK DETAIL HINT PATH)."
  (let ((helper (expand-file-name "scripts/roost_remote.py" roost--package-directory)))
    (list (list "Emacs" (version<= "29.1" emacs-version) emacs-version
                "Roost needs Emacs 29.1 or newer")
          (let ((version (roost--library-version "tmux-control")))
            (list "tmux-control" (and version (ignore-errors (version<= "0.7.0" version))) version
                  (if version
                      "Roost needs tmux-control 0.7.0 or newer: https://github.com/csheaff/tmux-control"
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
          (roost--doctor-notifications))))

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
  "Insert one check NAME with status OK, DETAIL and HINT; PATH is a tooltip."
  (insert "  "
          (pcase ok
            ('info (propertize "·" 'face 'roost-dim))
            ('optional (propertize "–" 'face 'roost-dim))
            ('nil (propertize "✗" 'face 'roost-status-failed))
            (_ (propertize "✓" 'face 'roost-status-ready)))
          ;; A long name, such as a project's push check, keeps a space.
          " " (string-pad name 15) " "
          (propertize (or (if (stringp detail) detail "") "") 'face 'roost-dim
                      'help-echo path)
          "\n")
  (when (and hint (memq ok '(nil optional)))
    (insert (propertize (concat "      " hint "\n")
                        'face (if ok 'roost-dim 'roost-status-permission)))))

(defun roost--render-doctor ()
  "Redraw the setup check from `roost--doctor-results'."
  (when-let* ((buffer (get-buffer "*roost doctor*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (default (if (equal roost-default-agent "pi") "Pi" (capitalize roost-default-agent))))
        (erase-buffer)
        (insert (propertize "Roost setup check" 'face 'roost-title) "\n\n"
                (propertize "Emacs" 'face 'roost-heading) "\n")
        (dolist (check (roost--doctor-local-checks))
          (apply #'roost--doctor-line check))
        (dolist (entry roost--doctor-results)
          (let ((result (cdr entry)))
            (insert "\n" (propertize (roost--host-label (car entry)) 'face 'roost-heading) "\n")
            (cond
             ((eq result 'pending) (insert (propertize "  Checking…\n" 'face 'roost-dim)))
             ((eq (car-safe result) 'error)
              (let ((hint (cdr (seq-find (lambda (hint) (string-match-p (regexp-quote (car hint)) (cdr result)))
                                         roost--ssh-hints))))
                (roost--doctor-line (if (car entry) "SSH and Python" "Python") nil (cdr result)
                                    (and hint (string-replace "HOST" (or (car entry) "localhost") hint)))))
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
        (insert "\n" (propertize (substitute-command-keys
                                   "\\<roost-doctor-mode-map>\\[roost-doctor] checks again · C-u \\[roost-doctor] checks another host")
                                  'face 'roost-dim)
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
                          roost--agents)))
    (setq roost--doctor-results (mapcar (lambda (host) (cons host 'pending)) hosts))
    (with-current-buffer (get-buffer-create "*roost doctor*")
      (unless (derived-mode-p 'roost-doctor-mode) (roost-doctor-mode)))
    (roost--render-doctor)
    (pop-to-buffer "*roost doctor*")
    (dolist (host hosts)
      (let ((host host))
        (roost--request
         host "doctor" (list (cons 'commands commands)
                             (cons 'projects (vconcat (roost--host-projects host))))
         (lambda (checks)
           (setf (alist-get host roost--doctor-results nil nil #'equal) checks)
           (roost--render-doctor))
         (lambda (err)
           (setf (alist-get host roost--doctor-results nil nil #'equal) (cons 'error err))
           (roost--render-doctor)))))))

;;;###autoload
(defcustom roost-mode-line-count t
  "Whether `roost-watch-mode' shows waiting agents in the mode line.
The count appears in `global-mode-string', which mode lines keep even
when they hide minor modes, and only while some agent waits."
  :type 'boolean)

(defun roost--mode-line-count (&optional plain)
  "\"Roost:N\" for the agents waiting for you, or nil when none are.
Agents asking permission or stuck at a startup prompt color the count.
PLAIN leaves out the status light, for a count no mode line shows."
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
      ;; A canvas has one background, so the light shows only in the
      ;; selected window's mode line, and only on a graphical frame.
      (concat (when (and (not plain) (roost--animations-p) (roost--light-frame-p (selected-frame))
                         (mode-line-window-selected-p))
                (propertize " " 'display
                            (roost--light 'mode-line 'waiting (if (> blocked 0) 'pulse 'glow)
                                          (roost--waiting-face tasks) 'mode-line-active)))
              (propertize (format " Roost:%d" (+ blocked waiting))
                          'face (roost--waiting-face tasks)
                          'help-echo "Agents waiting for you; mouse-1 opens the next"
                          'mouse-face 'mode-line-highlight
                          'local-map (make-mode-line-mouse-map 'mouse-1 #'roost-next-waiting))
              " "))))

(defun roost-mode-line-waiting ()
  "Return \" Roost:N \" while agents wait for you, for your own mode line.
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

(define-obsolete-function-alias 'roost-list #'roost-switch-task "0.9")
(define-obsolete-function-alias 'roost-kill #'roost-stop "0.9")

(provide 'roost)
;;; roost.el ends here
