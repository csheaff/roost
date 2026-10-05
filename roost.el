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

(declare-function tmux-control-connect-or-switch "tmux-control" (host socket-name session))
(declare-function tmux-control-send-command "tmux-control" (command))
(declare-function tmux-control-query "tmux-control" (command callback))
(declare-function tmux-control-select-pane "tmux-control" (&optional pane))
(declare-function tmux-control-tile "tmux-control" ())
(declare-function tmux-control-tiled-p "tmux-control" ())
(declare-function tmux-control-buffer-host "tmux-control" ())
(declare-function tmux-control-buffer-socket-name "tmux-control" ())
(declare-function tmux-control-active-pane "tmux-control" ())
(declare-function tmux-control-window-id "tmux-control" ())
(declare-function magit-status "magit-status" (&optional directory cache))
(declare-function magit-diff-working-tree "magit-diff" (&optional rev args files))
(declare-function persp-switch "perspective" (name))
(declare-function persp-kill "perspective" (name))
(declare-function persp-current-name "perspective" ())
(declare-function persp-names "perspective" ())
(declare-function persp-format-name "perspective" (name))
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-before-first-heading-p "org" ())
(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-entry-end-position "org" ())
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-entry-put "org" (epom property value))

(defvar tmux-control-default-socket-name)
(defvar tmux-control-remote-tmux-socket-setup)
(defvar tmux-control-ssh-options)
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

(defcustom roost-claude-command '("claude")
  "Claude executable and extra arguments, evaluated on the task host."
  :type '(repeat string))

(defcustom roost-default-agent "claude"
  "Default agent offered when creating a task.
Existing tasks retain their agent."
  :type '(choice (const "claude") (const "codex") (const "pi")))

(defcustom roost-agent-commands '(("codex" "codex") ("pi" "pi"))
  "Executable and extra arguments for each agent, evaluated on the task host.
Claude uses `roost-claude-command' unless overridden here."
  :type '(alist :key-type string :value-type (repeat string)))

(defconst roost--agents '("claude" "codex" "pi"))

(defcustom roost-setup-command nil
  "Optional project setup shell command, run before the agent in new worktrees.
May be set directory-locally.  Not rerun on resume."
  :type '(choice (const nil) string))

(defcustom roost-branch-prefix "roost/"
  "Prefix for task topic branches, which are named PREFIX<task>-<id>.
Existing tasks keep their branch."
  :type 'string)

(defcustom roost-socket-name nil
  "Tmux socket, or nil to use tmux-control's configured default."
  :type '(choice (const nil) string))

(defcustom roost-session-name nil
  "Tmux session to place new task windows in, or nil for one per repository.
Those are named after the repository, such as \"roost-notes-3f2a\"."
  :type '(choice (const nil) string))

(defcustom roost-startup-grace 15
  "Seconds after which a task still starting is taken to be waiting at a prompt.
Agents report nothing until their folder-trust or hook-review prompts
are answered, so a long start usually needs you."
  :type 'number)

(defcustom roost-watch-interval 3
  "Seconds between asynchronous status refreshes."
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

(defcustom roost-use-perspectives t
  "Allow `roost-workspace' to use perspective.el."
  :type 'boolean)

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

;;;; Faces

(defface roost-title '((t :inherit bold :height 1.1))
  "Titles of Roost buffers.")
(defface roost-heading '((t :inherit bold))
  "Group and section headings.")
(defface roost-dim '((t :inherit shadow))
  "Secondary text: labels, timestamps, prompts.")
(defface roost-key '((t :inherit help-key-binding))
  "Key bindings shown beside actions.")
(defface roost-field '((t :inherit link))
  "Clickable fields and actions.")
(defface roost-status-permission '((t :inherit warning :weight bold))
  "A task waiting for a permission answer in its terminal.")
(defface roost-status-ready '((t :inherit success))
  "A task waiting for your next prompt.")
(defface roost-status-running '((t :inherit font-lock-keyword-face))
  "A task whose agent is working.")
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
(defface roost-diff-added '((t :inherit success))
  "Inserted line counts.")
(defface roost-diff-removed '((t :inherit error))
  "Deleted line counts.")

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
(defvar roost--watch-timer nil)
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
  (let ((host (roost--field task 'host))
        (path (roost--field task 'worktree)))
    (if (not host)
        (file-name-as-directory path)
      (let* ((parts (split-string host "@"))
             (user (and (> (length parts) 1) (car parts)))
             (bare (car (last parts)))
             (method (substring-no-properties (tramp-find-method nil user bare))))
        (concat "/" method ":" host ":" (file-name-as-directory path))))))

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
  "Local argv executing Python CODE on HOST, without interpolating input."
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
                              "exec python3 -c " (shell-quote-argument code)))))
    (list "python3" "-c" code)))

(defun roost--decode-response (output)
  "Parse the last nonempty line of OUTPUT as the protocol response."
  (let ((line (car (last (split-string output "\n" t "[ \t\r]+")))))
    (unless line (error "The host helper returned no response"))
    (json-parse-string line :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defun roost--run (host code input success failure)
  "Execute CODE asynchronously on HOST with INPUT.
Call SUCCESS with the result or FAILURE with an error message."
  (let* ((buffer (generate-new-buffer " *roost-rpc*"))
         (errors (generate-new-buffer " *roost-rpc-errors*"))
         (default-directory temporary-file-directory)
         process timer finished timed-out)
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name "roost-rpc" :buffer buffer :stderr errors :noquery t
                 :coding 'utf-8-unix :connection-type 'pipe
                 :command (roost--python-command host code)
                 :sentinel
                 (lambda (proc _event)
                   (when (and (memq (process-status proc) '(exit signal)) (not finished))
                     (setq finished t
                           roost--requests (delq proc roost--requests))
                     (when timer (cancel-timer timer))
                     (unwind-protect
                         (let ((stdout (with-current-buffer buffer (buffer-string)))
                               (stderr (with-current-buffer errors
                                         (string-trim (buffer-string)))))
                           (condition-case parse-error
                               (if (= (process-exit-status proc) 0)
                                   (let ((response (roost--decode-response stdout)))
                                     (if (alist-get 'ok response)
                                         (funcall success (alist-get 'result response))
                                       (funcall failure (or (alist-get 'error response)
                                                            "Host operation failed"))))
                                 (funcall failure
                                          (cond (timed-out
                                                 (format "No reply after %ss; the operation may still finish on the host, so refresh before retrying"
                                                         roost-request-timeout))
                                                ((string-empty-p stderr) "Host operation failed")
                                                (t stderr))))
                             (error (funcall failure (error-message-string parse-error)))))
                       (kill-buffer buffer)
                       (kill-buffer errors))))))
          (push process roost--requests)
          (setq timer (run-at-time roost-request-timeout nil
                                   (lambda ()
                                     (when (process-live-p process)
                                       (setq timed-out t)
                                       (delete-process process)))))
          (process-send-string process input)
          (process-send-eof process))
      (error
       (when (and process (process-live-p process)) (delete-process process))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (when (buffer-live-p errors) (kill-buffer errors))
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
          (lambda ()
            (roost--run
             host
             (format "import os,runpy,sys; p=os.path.join(os.path.expanduser(%s),%s); sys.argv=[p,'rpc']; runpy.run_path(p,run_name='__main__')"
                     (json-serialize root) (json-serialize filename))
             (roost--json-encode (append (list (cons 'action action) (cons 'root root))
                                         parameters))
             success failure))))
    (if (equal (gethash installation-key roost--installed) filename)
        (funcall invoke)
      (roost--run
       host
       (format "import os,sys,tempfile,json\nr=os.path.expanduser(%s)\nos.makedirs(r,mode=0o700,exist_ok=True)\np=os.path.join(r,%s)\nfd,t=tempfile.mkstemp(dir=r)\nwith os.fdopen(fd,'wb') as f: f.write(sys.stdin.buffer.read())\nos.chmod(t,0o700)\nos.replace(t,p)\nprint(json.dumps({'ok':True}))"
               (json-serialize root) (json-serialize filename))
       (cdr helper)
       (lambda (_)
         (puthash installation-key filename roost--installed)
         (funcall invoke))
       failure))))

;;;; Status cache and notifications

(defun roost--notify (title body)
  "Display notification TITLE with BODY."
  (cond ((functionp roost-notify-function)
         (funcall roost-notify-function title body))
        ((executable-find "terminal-notifier")
         (call-process "terminal-notifier" nil 0 nil "-title" title "-message" body))
        ((eq system-type 'darwin)
         (call-process "osascript" nil 0 nil "-e"
                       (format "display notification %S with title %S" body title)))
        ((fboundp 'notifications-notify)
         (notifications-notify :title title :body body))
        (t (message "%s: %s" title body))))

(defun roost--cache-task (host task)
  "Cache TASK from HOST and notify only on attention transitions."
  (setf (alist-get 'host task) host)
  (setq task (assq-delete-all 'pushed task))
  (let* ((key (roost--key task))
         (old (gethash key roost--tasks))
         (status (roost--field task 'status))
         (previous (gethash key roost--statuses))
         (new-stop (and (equal status "ready")
                        (equal (roost--field task 'lastEvent) "Stop")
                        (not (equal (roost--field task 'updatedAt)
                                    (roost--field old 'updatedAt))))))
    ;; Quiet polls skip Git and the latest reply; keep the last full refresh's.
    (dolist (field '(diff dirty files ahead behind worktreeMissing prStatus lastMessage))
      (unless (assoc field task)
        (when (assoc field old) (push (assoc field old) task))))
    (if (member status '("retired" "forgotten"))
        (remhash key roost--tasks)
      (puthash key task roost--tasks))
    ;; Record the status before notifying, which may cache this task again.
    (puthash key status roost--statuses)
    (when (and roost-notify previous
               (or (not (equal previous status)) new-stop)
               (or (not (equal previous "starting")) new-stop)
               (member status '("ready" "permission" "failed" "crashed" "exited")))
      (roost--notify-attention host task status))
    task))

(defun roost--notify-attention (host task status)
  "Notify that TASK on HOST became STATUS.
A ready agent or one asking permission is inspected first, since quiet
polls leave out its latest reply, so the notification can say what it
finished or wants."
  (let ((title (format "Roost: %s — %s" (roost--field task 'name) status))
        (label (roost--host-label host)))
    (if (not (member status '("ready" "permission")))
        (roost--notify title label)
      (roost--request
       host "inspect" (list (cons 'id (roost--field task 'id)))
       (lambda (current)
         (setq current (roost--cache-task host current))
         (roost--redraw)
         (roost--notify title
                        (if-let* ((reply (roost--last-message-summary current)))
                            (concat label " · " (truncate-string-to-width reply 160 nil nil "…"))
                          label)))
       (lambda (_error) (roost--notify title label))))))

(defun roost--apply-snapshot (host tasks)
  "Replace only HOST's cached tasks with a successful snapshot TASKS."
  (let ((keys (mapcar (lambda (task) (list host (roost--field task 'id))) tasks)))
    (maphash (lambda (key _)
               (when (and (equal (car key) host) (not (member key keys)))
                 (remhash key roost--tasks)
                 (remhash key roost--statuses)
                 (remhash key roost--seen)))
             roost--tasks)
    (mapc (lambda (task) (roost--cache-task host task)) tasks)
    (remhash host roost--errors)))

(defun roost--task-states (host)
  "HOST's cached tasks as an alist of ID to (STATUS . UPDATED-AT).
Each agent hook event, such as finishing a tool, moves UPDATED-AT."
  (let (states)
    (maphash (lambda (key task)
               (when (equal (car key) host)
                 (push (cons (cadr key) (cons (roost--field task 'status)
                                              (roost--field task 'updatedAt)))
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
    (let ((revision (gethash host roost--revisions 0))
          (finish (lambda ()
                    (remhash host roost--refreshing)
                    (when-let* ((pending (gethash host roost--full-refresh-pending)))
                      (remhash host roost--full-refresh-pending)
                      (roost--refresh-host host nil (unless (eq pending t) pending))))))
      (roost--request
       host "list" (list (cons 'full (cond (quiet :false) (ids (vconcat ids)) (t t))))
       (lambda (tasks)
         (remhash host roost--failures)
         (remhash host roost--errors)
         ;; A newer mutation must win over a stale list reply.
         (when (= revision (gethash host roost--revisions 0))
           (let ((before (roost--task-states host)))
             (roost--apply-snapshot host tasks)
             ;; Quiet polls leave out Git statistics.  An agent that reported
             ;; something, such as finishing an edit, may have changed files:
             ;; measure its task once this poll is done.
             (when-let* ((quiet)
                         (changed (seq-keep (lambda (state)
                                              (unless (equal state (assoc (car state) before))
                                                (car state)))
                                            (roost--task-states host))))
               (roost--refresh-host host nil changed))))
         (roost--redraw)
         (funcall finish))
       (lambda (err)
         (unless (equal err (gethash host roost--errors))
           (message "Roost %s: %s (M-x roost-doctor checks this host)" (roost--host-label host) err))
         (puthash host err roost--errors)
         ;; Back off from unreachable hosts, up to a minute between attempts.
         (let ((count (1+ (or (car (gethash host roost--failures)) 0))))
           (puthash host (cons count (+ (float-time)
                                        (min 60 (* roost-watch-interval (expt 2 (1- count))))))
                    roost--failures))
         (remhash (list host roost-state-directory) roost--installed)
         (roost--redraw)
         (funcall finish))))))

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
  '("permission" "prompt" "ready" "failed" "crashed" "running" "background" "idle"
    "starting" "exited" "stopped")
  "Attention statuses from most to least in need of attention.")

(defun roost--attention-status (task)
  "TASK's status for attention.
That is \"prompt\" when it has been starting too long, and \"idle\" when
it is ready and you have seen it since, rather than \"ready\"."
  (let ((status (roost--display-status task)))
    (cond ((and (equal status "starting")
                (> (or (roost--seconds-since (roost--field task 'updatedAt)) 0)
                   roost-startup-grace))
           "prompt")
          ((and (equal status "ready")
                (equal (gethash (roost--key task) roost--seen) (roost--field task 'updatedAt))
                (roost--field task 'updatedAt))
           "idle")
          (t status))))

(defun roost--mark-seen (task)
  "Record that you have seen TASK's agent as it is now."
  (puthash (roost--key task) (roost--field task 'updatedAt) roost--seen))

(defun roost--note-watched-agent ()
  "Mark seen the agent whose terminal is in the selected window.
Only while Emacs has focus, since otherwise nobody is looking."
  (when (and (frame-focus-state) (fboundp 'tmux-control-active-pane))
    (with-current-buffer (window-buffer (selected-window))
      (when-let* ((pane (tmux-control-active-pane))
                  (task (seq-find (lambda (task)
                                    (and (equal (roost--field task 'paneId) pane)
                                         (equal (roost--field task 'host) (tmux-control-buffer-host))
                                         (equal (roost--field task 'socket)
                                                (tmux-control-buffer-socket-name))))
                                  (roost-tasks))))
        (roost--mark-seen task)))))

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
              (concat "  " (propertize status 'face (roost--status-face status))
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
   ((derived-mode-p 'roost-dashboard-mode)
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
       (when-let* ((pane (and (fboundp 'tmux-control-active-pane)
                              (tmux-control-active-pane))))
         (seq-find (lambda (task)
                     (and (equal (roost--field task 'host) (tmux-control-buffer-host))
                          (equal (roost--field task 'socket) (tmux-control-buffer-socket-name))
                          (member pane (list (roost--field task 'paneId)
                                             (roost--field task 'shellPaneId)))))
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

(defun roost--perspective-name (task)
  "Unique workspace name for TASK."
  (format "roost:%s:%s:%s"
          (roost--host-label (roost--field task 'host))
          (roost--field task 'name)
          (substring (roost--field task 'id) 0 6)))

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
  (if (not (and original roost-compact-mode-line roost-use-perspectives
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
  (let ((perspective (and roost-use-perspectives (bound-and-true-p persp-mode)
                          (fboundp 'persp-current-name))))
    (pcase roost-workspace
      ('auto (cond (perspective 'perspective)
                   ((bound-and-true-p tab-bar-mode) 'tab-bar)))
      ('perspective (and perspective 'perspective))
      ('tab-bar 'tab-bar))))

(defun roost--tab-name (task)
  "Tab name for TASK, with its ID when another task has the same name."
  (let* ((host (roost--field task 'host))
         (name (roost--field task 'name))
         (twin (seq-find (lambda (other)
                           (and (equal (roost--field other 'host) host)
                                (equal (roost--field other 'name) name)
                                (not (equal (roost--field other 'id) (roost--field task 'id)))))
                         (roost-tasks))))
    (format "%s/%s%s" (roost--host-label host) name
            (if twin (concat ":" (substring (roost--field task 'id) 0 6)) ""))))

(defun roost--tabs ()
  "Names of the tab bar's tabs."
  (mapcar (lambda (tab) (alist-get 'name tab)) (funcall tab-bar-tabs-function)))

(defun roost--workspace-name (task)
  "Name of TASK's workspace in the current backend."
  (if (eq (roost--workspace-backend) 'tab-bar)
      (roost--tab-name task)
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
     (when (fboundp 'persp-switch) (persp-switch (roost--perspective-name task))))
    ('tab-bar
     (let ((name (roost--tab-name task)))
       (if (member name (roost--tabs))
           (tab-bar-select-tab-by-name name)
         (tab-bar-new-tab)
         (tab-bar-rename-tab name)))))
  (setq roost--current-task (roost--key task))
  ;; Without workspaces, the frame's task panel follows the last task used.
  (set-frame-parameter nil 'roost-task (roost--key task))
  (roost--leave-side-window))

;;;; Opening tasks

(defun roost--display-task (task &optional target-pane)
  "Display TASK after ownership validation, selecting TARGET-PANE if supplied."
  (require 'tmux-control)
  (roost--leave-side-window)
  (roost--activate-workspace task)
  (roost--leave-side-window)
  ;; Reuse the saved terminal window instead of replacing its neighboring
  ;; code or Magit window when that happened to be selected on departure.
  ;; A tiled pane's window is left alone: the session buffer would replace
  ;; that pane in the grid.
  (when-let* ((window
               (seq-find (lambda (window)
                           (with-current-buffer (window-buffer window)
                             (and (tmux-control-window-id)
                                  (not (tmux-control-tiled-p))
                                  (equal (tmux-control-buffer-host) (roost--field task 'host))
                                  (equal (tmux-control-buffer-socket-name) (roost--field task 'socket))
                                  (equal (tmux-control-window-id) (roost--field task 'windowId)))))
                         (window-list))))
    (select-window window))
  (tmux-control-connect-or-switch (roost--field task 'host) (roost--field task 'socket)
                                  (roost--field task 'session))
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
  (when (roost--task-panel-window)
    (roost--refresh-host (roost--field task 'host) nil)))

;;;###autoload
(defun roost-open-task (&optional task)
  "Validate TASK's tmux ownership, then restore its perspective and terminal."
  (interactive)
  (setq task (roost--choose task))
  (let ((generation (cl-incf roost--open-generation)))
    (roost--request (roost--field task 'host) "inspect"
                    (list (cons 'id (roost--field task 'id)))
                    (lambda (current)
                      (setq current (roost--cache-task (roost--field task 'host) current))
                      (when (= generation roost--open-generation)
                        (roost--display-task current)
                        (when (and (assq 'live current) (not (roost--field current 'live)))
                          (message "%s's agent has %s; its last output is shown. Resume with `s'."
                                   (roost--field current 'name)
                                   (roost--field current 'status))))))))

;;;###autoload
(defun roost-switch-task ()
  "Choose a task across hosts and restore its workspace."
  (interactive)
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
                                                                   "[^[:alnum:]-]+" " " (or text "")))
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
      (and (equal agent "claude") roost-claude-command)
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
           ,(cons 'socket (or roost-socket-name
                              (bound-and-true-p tmux-control-default-socket-name)
                              "main"))
           ,(cons 'session roost-session-name)
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
  "Default project for a new task, given the TASK in context and FORK."
  (cond (task (if fork (roost--remote-directory task) (roost--project-directory task)))
        ((ignore-errors (vc-root-dir)))
        ((car (roost--known-projects)))))

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
              (list :directory (roost--compose-default-directory task fork)
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
    (pop-to-buffer buffer)))

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

(defun roost--choose-from (prompt choices &optional default)
  "Choose from CHOICES, an alist of (LABEL . VALUE), with PROMPT.
A mouse click shows a menu at the pointer; the keyboard uses the minibuffer."
  (if (and (mouse-event-p last-nonmenu-event) (display-popup-menus-p))
      (x-popup-menu last-nonmenu-event (list prompt (cons "" choices)))
    (cdr (assoc (completing-read prompt choices nil t nil nil default) choices))))

(defun roost-compose-set-project ()
  "Choose the draft's project from known checkouts, or any directory."
  (interactive)
  (let* ((other "Other directory…")
         (choices (append (mapcar (lambda (dir) (cons (roost--project-label dir) dir))
                                  (roost--known-projects))
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
    (let* ((issue (cdr (assoc (completing-read "Issue: " choices nil t) choices)))
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

(defun roost--act (task action &optional parameters callback failure)
  "Run ACTION on TASK with PARAMETERS, then CALLBACK with the updated task.
FAILURE, if given, receives the error message instead of Roost reporting it."
  (let ((host (roost--field task 'host)))
    (roost--request host action (cons (cons 'id (roost--field task 'id)) parameters)
                    (lambda (updated)
                      (cl-incf (gethash host roost--revisions 0))
                      ;; `pushed' is transient: the callback sees it, the cache does not.
                      (let ((pushed (assq 'pushed updated)))
                        (setq updated (roost--cache-task host updated))
                        (roost--redraw)
                        (message "Roost %s: %s" (roost--field task 'name) action)
                        (when callback
                          (funcall callback (if pushed (cons pushed updated) updated)))))
                    failure)))

;;;###autoload
(defun roost-resume (&optional task)
  "Restart TASK, resuming its recorded agent conversation."
  (interactive)
  (roost--act (roost--choose task) "resume" nil #'roost-open-task))

;;;###autoload
(defun roost-send (&optional task text)
  "Send TEXT as a literal pasted prompt to TASK's agent pane.
Interactively, write the prompt in a draft buffer; \\<roost-send-mode-map>\\[roost-send-submit] sends it.
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
  "Open a draft buffer for a follow-up to TASK, starting with INITIAL.
An existing draft for TASK is reused, and kept as written unless it is empty."
  (let* ((name (format "*roost send: %s*" (roost--field task 'name)))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-send-mode) (roost-send-mode))
      (setq roost--send-task task
            header-line-format (roost--send-header task))
      (when (and initial (string-empty-p (string-trim (buffer-string))))
        (erase-buffer)
        (insert initial)
        ;; Leave point above the quoted text, ready for a note.
        (goto-char (point-min)))
      (unless (and initial (bobp))
        (goto-char (point-max))))
    (pop-to-buffer buffer)))

(defun roost-send-cancel ()
  "Discard the follow-up draft."
  (interactive)
  (when (or (string-empty-p (string-trim (buffer-string)))
            (yes-or-no-p "Discard this prompt? "))
    (quit-window t)))

(defun roost-send-submit ()
  "Send the drafted follow-up.  The draft is kept if sending fails."
  (interactive)
  (let ((text (string-trim-right (buffer-string)))
        (task roost--send-task)
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
chosen one."
  (interactive "r")
  (let* ((last (if (and (> end start) (eq (char-before end) ?\n)) (1- end) end))
         (task (or (and buffer-file-name (roost--task-in-directory buffer-file-name))
                   (roost--read-task "Send region to task: "))))
    (roost--send-draft
     task
     (format "\n\n%s:%d-%d\n\n%s"
             (cond ((and buffer-file-name (roost--worktree-relative task buffer-file-name)))
                   (buffer-file-name (file-local-name buffer-file-name))
                   (t (buffer-name)))
             (line-number-at-pos start) (line-number-at-pos last)
             (buffer-substring-no-properties start end)))))

;;;###autoload
(defun roost-review (&optional task)
  "Open Magit on TASK's worktree, through TRAMP for remote tasks."
  (interactive)
  (setq task (roost--choose task))
  (roost--activate-workspace task)
  (if (not (require 'magit nil t))
      (dired (roost--remote-directory task))
    (add-hook 'magit-post-refresh-hook #'roost--magit-refreshed)
    (magit-status (roost--remote-directory task))))

(defun roost--magit-refreshed ()
  "Measure the task whose worktree Magit has just refreshed.
Commits and staging there change the task's Git statistics, with no
agent event to prompt a refresh."
  (when-let* ((task (roost--task-in-directory default-directory)))
    (roost--refresh-host (roost--field task 'host) nil (list (roost--field task 'id)))))

;;;###autoload
(defun roost-files (&optional task)
  "Browse TASK's worktree with Dired."
  (interactive)
  (setq task (roost--choose task))
  (roost--activate-workspace task)
  (dired (roost--remote-directory task)))

;;;###autoload
(defun roost-shell (&optional task)
  "Open or reuse a shell beside the agent, in TASK's worktree."
  (interactive)
  (setq task (roost--choose task))
  (let ((generation (cl-incf roost--open-generation)))
    (roost--act task "shell" nil
                (lambda (updated)
                  (when (= generation roost--open-generation)
                    (roost--display-task updated (roost--field updated 'shellPaneId))
                    (with-current-buffer (window-buffer (selected-window))
                      (unless (tmux-control-tiled-p) (tmux-control-tile))
                      (roost--focus-shell updated generation)))))))

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
  (require 'magit)
  (roost--activate-workspace task)
  (let ((default-directory (roost--remote-directory task)))
    (magit-diff-working-tree (roost--fork-point task))))

;;;###autoload
(defun roost-update (&optional task)
  "Merge TASK's integration branch into its worktree.
This brings a task that fell behind up to date before merging it, and
resolves conflicts in the task rather than the primary checkout.  On
conflicts, offer to have the task's agent resolve them."
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
              (if (yes-or-no-p (format "%s conflicts with %s in %s. Ask its agent to resolve them? "
                                       name branch (string-join conflicts ", ")))
                  (roost-send updated
                              (format "I merged %s into this branch and Git reports conflicts in: %s. Resolve the conflicts so the changes from both sides keep working, run the tests, and commit the merge."
                                      branch (string-join conflicts ", ")))
                (message "The merge is in progress in %s's worktree; resolve it in Magit (r) and commit"
                         name)))
             ((alist-get 'changed result)
              (message "%s now includes the latest %s" name branch))
             (t (message "%s is already up to date with %s" name branch)))))))

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
  (let* ((buffer (get-buffer-create (format "*roost pr: %s*" (roost--field task 'name)))))
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
      (if (or skip-push
              (member (alist-get 'state (roost--field task 'prStatus)) '("MERGED" "CLOSED")))
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
Without a status from GitHub yet, a recorded pull request counts as open."
  (when (roost--field task 'pr)
    (let ((status (roost--field task 'prStatus)))
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
         (substitute-command-keys
          "Merged on GitHub. \\<roost-task-info-mode-map>\\[roost-retire] retires this task, removing its worktree and branch.")
         'roost-dim)))))

;;;###autoload
(defun roost-stop (&optional task)
  "Stop TASK's window, retaining its worktree, branch and conversation."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Stop %s's window and its processes, keeping its work? "
                             (roost--field task 'name)))
    (roost--act task "stop")))

;;;###autoload
(defun roost-retire (&optional task)
  "Remove TASK's clean, merged worktree and branch, then stop its window."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Retire %s, removing its merged worktree and branch? "
                             (roost--field task 'name)))
    (roost--act task "retire" nil
                (lambda (retired)
                  (roost--retired-workspace retired)
                  (roost--kill-worktree-buffers retired)))))

;;;###autoload
(defun roost-merge-retire (&optional task)
  "Merge TASK's committed work into its recorded integration branch and retire.
Dirty worktrees are refused; review and commit in Magit first."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Merge committed work from %s and retire it? "
                             (roost--field task 'name)))
    (roost--act task "merge" nil
                (lambda (merged)
                  (roost--retired-workspace merged)
                  (roost--kill-worktree-buffers merged)
                  ;; The other tasks are measured against the branch that moved.
                  (roost--refresh-host (roost--field merged 'host) nil)
                  (message "Merged %s into %s, and removed its worktree and branch"
                           (roost--field task 'name)
                           (or (roost--field task 'integrationBranch) "its branch"))))))

;;;###autoload
(defun roost-forget (&optional task)
  "Drop TASK's record from Roost without touching its worktree or branch.
For tasks Roost can no longer retire, such as one whose repository moved.
A running agent must be stopped first."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Forget %s, leaving its worktree and branch as they are? "
                             (roost--field task 'name)))
    (roost--act task "forget" nil
                (lambda (forgotten)
                  (roost--retired-workspace forgotten)
                  (when-let* ((left (roost--field forgotten 'leftBehind)))
                    (message "Forgot %s; left in place: %s"
                             (roost--field task 'name) (string-join left ", ")))))))

(defun roost--kill-worktree-buffers (task)
  "Kill the Magit and Dired buffers left in TASK's removed worktree.
File buffers stay, since they may hold unsaved edits."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'magit-mode 'dired-mode)
                 (roost--task-in-directory default-directory (list task)))
        (kill-buffer buffer)))))

(defun roost--retired-workspace (task)
  "Remove TASK's workspace, retaining buffers."
  (pcase (roost--workspace-backend)
    ('perspective
     (when (fboundp 'persp-kill)
       (let ((persp-autokill-buffer-on-remove nil))
         (persp-kill (roost--perspective-name task)))))
    ('tab-bar
     (let ((name (roost--tab-name task)))
       (when (and (member name (roost--tabs)) (cdr (roost--tabs)))
         (tab-bar-close-tab-by-name name))))))

;;;###autoload
(defun roost-next-waiting ()
  "Open the next task whose agent is waiting for you.
Permission requests and agents stuck at a startup prompt come first,
since they block their agent; then tasks ready for a prompt, in turn."
  (interactive)
  (let* ((waiting (sort (seq-filter (lambda (task)
                                      (member (roost--attention-status task)
                                              '("permission" "prompt" "ready")))
                                    (roost-tasks))
                        (lambda (a b) (< (roost--attention-rank a) (roost--attention-rank b)))))
         (keys (mapcar #'roost--key waiting))
         ;; The task you are looking at, which is never the dashboard's row:
         ;; a blocked task you just created or left must still come first.
         (viewing (unless (derived-mode-p 'roost-dashboard-mode)
                    (when-let* ((task (ignore-errors (roost--task-at-point))))
                      (roost--key task))))
         (blocked (seq-find (lambda (task)
                              (and (member (roost--attention-status task) '("permission" "prompt"))
                                   (not (equal (roost--key task) viewing))))
                            waiting))
         (key (if blocked
                  (roost--key blocked)
                (or (cadr (member (or viewing roost--current-task) keys)) (car keys)))))
    (unless key (user-error "No tasks are waiting for you"))
    (roost-open-task (gethash key roost--tasks))))

(defun roost--project-name (task)
  "Short primary repository name for TASK."
  (file-name-nondirectory (directory-file-name (or (roost--field task 'repo) "unknown"))))

;;;; Shared display helpers

(defun roost--display-status (task)
  "TASK's status, or \"offline\" while its host is unreachable."
  (if (gethash (roost--field task 'host) roost--errors) "offline" (roost--field task 'status)))

(defun roost--status-face (status)
  "Face for STATUS."
  (pcase status
    ((or "permission" "prompt") 'roost-status-permission)
    ("ready" 'roost-status-ready)
    ((or "running" "background") 'roost-status-running)
    ((or "failed" "crashed") 'roost-status-failed)
    (_ 'roost-status-inactive)))

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

(defun roost--changes (task &optional compact)
  "Git summary for TASK from the last full refresh.
COMPACT abbreviates commits ahead of and behind the integration branch."
  (let* ((diff (or (roost--field task 'diff) ""))
         (count (lambda (pattern)
                  (if (string-match (concat "\\([0-9]+\\) " pattern) diff)
                      (string-to-number (match-string 1 diff))
                    0)))
         (files (funcall count "files? changed"))
         (ahead (or (roost--field task 'ahead) 0))
         (behind (or (roost--field task 'behind) 0))
         (commits (delq nil (list (when (> ahead 0) (format (if compact "↑%d" "%d ahead") ahead))
                                  (when (> behind 0) (format (if compact "↓%d" "%d behind") behind))))))
    (string-join
     (delq nil (list (when (> files 0)
                       (format "%d file%s +%d −%d" files (if (= files 1) "" "s")
                               (funcall count "insertions?") (funcall count "deletions?")))
                     (when (roost--field task 'dirty) "uncommitted")
                     (when commits (string-join commits (if compact " " " · ")))))
     " · ")))

(defconst roost--changed-files-shown 12
  "How many changed files a task panel lists before summing up the rest.")

(defun roost--insert-changed-files (task width)
  "Insert TASK's changed files as buttons that show them, within WIDTH columns."
  (let ((files (roost--field task 'files)))
    (dolist (file (seq-take files roost--changed-files-shown))
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
                                (concat "…" (substring path (- (length path) (1- room))))
                              path)
                            'follow-link t 'face 'roost-field
                            'help-echo (concat path "\nmouse-1: show its changes")
                            'action (lambda (_) (roost--diff-file task file)))
        (insert "  " counts "\n")))
    (when (length> files roost--changed-files-shown)
      (roost--insert-indented
       (substitute-command-keys
        (format "and %d more; \\<roost-task-info-mode-map>\\[roost-diff] shows every change"
                (- (length files) roost--changed-files-shown)))
       'roost-dim))))

(defun roost--diff-file (task file)
  "Show how TASK has changed FILE, an entry of its `files'.
An untracked file, with nothing to compare, is opened instead."
  (roost--activate-workspace task)
  (let ((default-directory (roost--remote-directory task))
        (path (alist-get 'path file)))
    (if (and (not (alist-get 'untracked file)) (require 'magit nil t))
        (magit-diff-working-tree (roost--fork-point task) nil (list path))
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

(defun roost--strip-markdown (text)
  "TEXT without Markdown emphasis delimiters and the backticks of inline code.
Delimiters are removed only where they wrap text, so identifiers such as
snake_case_name and expressions such as a * b are kept, and so is
everything inside inline code."
  (let ((code nil)
        (text (or text "")))
    (setq text (replace-regexp-in-string
                "\\(`+\\)\\([^`\n]\\|[^`\n][^\n]*?[^`\n]\\)\\1"
                (lambda (match)
                  ;; A run of backticks closes at a run of the same length;
                  ;; one space inside each end is padding, as in `` `a` ``.
                  (let ((inner (match-string 2 match)))
                    (save-match-data
                      (when (string-match "\\` \\(.*\\) \\'" inner)
                        (setq inner (match-string 1 inner))))
                    (push inner code))
                  (format "\ue000%d\ue001" (1- (length code))))
                text t t))
    (let ((previous nil))
      (while (not (equal previous text))
        (setq previous text
              text (replace-regexp-in-string
                    (concat "\\(^\\|[^[:alnum:]*_]\\)"
                            "\\(\\*\\{1,3\\}\\|_\\{1,2\\}\\)"
                            "\\([^[:space:]]\\(?:[^\n]*?[^[:space:]]\\)??\\)"
                            "\\2\\($\\|[^[:alnum:]*_.]\\|\\.\\($\\|[[:space:]]\\)\\)")
                    "\\1\\3\\4" text))))
    (setq code (nreverse code))
    (replace-regexp-in-string
     "\ue000\\([0-9]+\\)\ue001"
     (lambda (match)
       (nth (string-to-number (substring match 1 -1)) code))
     text t t)))

(defun roost--last-message (task)
  "TASK's latest agent reply with Markdown markers removed, or nil."
  (let ((message (roost--field task 'lastMessage)))
    (when (stringp message)
      (let ((text (string-trim (roost--strip-markdown message))))
        (unless (string-empty-p text) text)))))

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
                      'roost-send-mode 'roost-pr-mode)
    (display-line-numbers-mode -1)
    (when (derived-mode-p 'roost-dashboard-mode)
      (visual-line-mode -1)
      (setq truncate-lines t))))

(defconst roost--task-menu-items
  '(["Open agent terminal" roost-open-task]
    ["Shell beside agent" roost-shell]
    ["Browse files" roost-files]
    ["Send prompt…" roost-send]
    "---"
    ["Review in Magit" roost-review]
    ["Diff the task's changes" roost-diff]
    ["Update from integration branch" roost-update]
    "---"
    ["Pull request…" roost-pr]
    ["Merge and retire…" roost-merge-retire]
    ["Retire…" roost-retire]
    ["Forget…" roost-forget]
    "---"
    ["Stop…" roost-stop]
    ["Resume" roost-resume]
    ["Details" roost-task-info])
  "Menu items acting on the task at point.")

(easy-menu-define roost-task-menu nil
  "Actions on the selected Roost task."
  (cons "Roost task" roost--task-menu-items))

;;;; Task panel

(defvar transient--original-buffer)

(defun roost--dispatch-task-description ()
  "Heading for `roost-dispatch' naming the task its commands act on.
Transient formats headings in a temporary buffer; the task comes from
the buffer the menu was opened from."
  (if-let* ((task (with-current-buffer (if (buffer-live-p transient--original-buffer)
                                           transient--original-buffer
                                         (current-buffer))
                    (ignore-errors (roost--task-at-point)))))
      (format "Task %s (%s)" (propertize (roost--field task 'name) 'face 'roost-title)
              (roost--display-status task))
    "Task (chosen when needed)"))

;;;###autoload (autoload 'roost-dispatch "roost" nil t)
(transient-define-prefix roost-dispatch ()
  "Show Roost's commands.
Task commands act on the task at point, in the dashboard, a task panel,
terminal or worktree, or ask which task."
  [:description roost--dispatch-task-description
   ["Work"
    ("RET" "Agent" roost-open-task)
    ("t" "Shell" roost-shell)
    ("f" "Files" roost-files)
    ("e" "Send prompt" roost-send)
    ("i" "Details" roost-task-info)]
   ["Review"
    ("r" "Magit" roost-review)
    ("D" "Diff" roost-diff)
    ("u" "Update from integration" roost-update)]
   ["Finish"
    ("P" "Pull request" roost-pr)
    ("m" "Merge and retire" roost-merge-retire)
    ("x" "Retire" roost-retire)
    ("X" "Forget" roost-forget)]
   ["Session"
    ("K" "Stop" roost-stop)
    ("s" "Resume" roost-resume)]]
  ["Roost"
   [("c" "New task" roost-new-task)
    ("n" "Next waiting" roost-next-waiting)
    ("l" "Switch task" roost-switch-task)]
   [("S" "Dashboard" roost-status)
    ("g" "Refresh" roost-refresh)
    ("w" "Watch hosts" roost-watch-mode)]
   [("b" "Sidebar" roost-sidebar-mode)
    ("I" "Task panel" roost-task-panel-mode)
    ("!" "Setup check" roost-doctor)]])

(defvar-keymap roost-task-info-mode-map
  :doc "Actions on the task shown in this buffer."
  "h" #'roost-dispatch
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
  "I" #'roost-task-panel-mode
  "q" #'roost-task-info-quit
  "g" #'roost-task-info-refresh)

(easy-menu-define roost-task-info-menu roost-task-info-mode-map
  "Menu for a Roost task panel."
  (cons "Roost" roost--task-menu-items))

(define-derived-mode roost-task-info-mode special-mode "Roost Task"
  "A task's prompt, changes, actions and details.
Status is the last observation from the task's host.
\\{roost-task-info-mode-map}"
  (setq-local truncate-lines nil
              ;; A docked panel is narrower than the default threshold of 50.
              truncate-partial-width-windows nil
              word-wrap t
              ;; As in `visual-line-mode', wrapped lines need no fringe arrows.
              fringe-indicator-alist (cons '(continuation nil nil)
                                           (default-value 'fringe-indicator-alist)))
  (add-hook 'after-change-major-mode-hook #'roost--quiet-display 90 t)
  (add-hook 'window-size-change-functions #'roost--task-info-resized nil t)
  (roost--evil-state 'roost-task-info-mode roost-evil-state)
  (roost--quiet-display))

(defconst roost--task-actions
  '(("Work" ("Agent" "RET" roost-open-task) ("Shell" "t" roost-shell)
     ("Files" "f" roost-files) ("Send prompt" "e" roost-send))
    ("Review" ("Magit" "r" roost-review) ("Diff" "D" roost-diff)
     ("Update" "u" roost-update))
    ("Finish" ("Pull request" "P" roost-pr) ("Merge and retire" "m" roost-merge-retire) ("Retire" "x" roost-retire)
     ("Forget" "X" roost-forget))
    ("Session" ("Stop" "K" roost-stop) ("Resume" "s" roost-resume)))
  "Task panel actions as (GROUP (LABEL KEY COMMAND)...).")

(defun roost--insert-action-button (action)
  "Insert a button for ACTION, a (LABEL KEY COMMAND) from `roost--task-actions'."
  (insert-text-button (nth 0 action) 'follow-link t 'face 'roost-field
                      'roost-command (nth 2 action)
                      'action (lambda (button)
                                (call-interactively (button-get button 'roost-command)))))

(defun roost--insert-narrow-actions (width)
  "Insert the task actions as KEY LABEL items flowing within WIDTH columns.
For a panel in a narrow window, such as beside a task's terminal."
  (dolist (group roost--task-actions)
    (insert "  ")
    (let ((first t))
      (dolist (action (cdr group))
        (let ((item (+ (string-width (nth 1 action)) 1 (string-width (nth 0 action)))))
          (when (and (not first) (> (+ (current-column) 3 item) width))
            (insert "\n  ")
            (setq first t))
          (unless first (insert (propertize " · " 'face 'roost-dim)))
          (insert (propertize (nth 1 action) 'face 'roost-key) " ")
          (roost--insert-action-button action)
          (setq first nil))))
    (insert "\n")))

(defun roost--task-info-width ()
  "Columns in the narrowest window showing the current task panel."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows (apply #'min (mapcar #'window-body-width windows)) 80)))

(defun roost--task-info-resized (window)
  "Reflow the task panel after WINDOW is resized."
  (with-current-buffer (window-buffer window)
    (roost--render-task-info)))

(defun roost--insert-heading (title)
  "Insert section TITLE."
  (insert "\n" (propertize title 'face 'roost-heading) "\n"))

(defvar-local roost--show-full-prompt nil
  "Non-nil when the task panel shows a long prompt in full.")

(defvar-local roost--expanded-reply nil
  "The reply expanded in a compact panel, or nil.
A different reply starts collapsed when it arrives.")

(defun roost--reply-preview (reply width)
  "The first six wrapped lines of REPLY, fitting WIDTH columns.
Return short replies unchanged."
  (let* ((columns (max 12 (- width 2)))
         (lines (with-temp-buffer
                  (let ((fill-column columns) wrapped)
                    ;; Preserve explicit newlines, including lists and code.
                    (dolist (source-line (split-string reply "\n"))
                      (erase-buffer)
                      (insert source-line)
                      (fill-region (point-min) (point-max))
                      (dolist (line (split-string (buffer-string) "\n"))
                        ;; Fill leaves long URLs and unbroken tokens alone.
                        (while (> (string-width line) columns)
                          (let ((part (truncate-string-to-width line columns)))
                            (push part wrapped)
                            (setq line (substring line (length part)))))
                        (push line wrapped)))
                    (nreverse wrapped)))))
    (if (<= (length lines) 6)
        reply
      (concat (string-join (seq-take lines 5) "\n") "\n"
              (truncate-string-to-width (string-trim-right (nth 5 lines))
                                        (1- columns))
              "…"))))

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

(defun roost--insert-reply-toggle (reply expanded)
  "Insert a button to expand REPLY, or collapse it when EXPANDED."
  (let ((start (point)))
    (insert-text-button (if expanded "Collapse reply" "Show the whole reply")
                        'follow-link t 'face 'roost-field
                        'action (lambda (_)
                                  (setq roost--expanded-reply (unless expanded reply))
                                  (roost--render-task-info)))
    (insert "\n")
    (put-text-property start (point) 'line-prefix "  ")))

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

(defun roost--render-task-info ()
  "Update the current task panel from the cache, without changing focus.
Windows showing the panel keep their scroll position."
  (let ((task (gethash roost--buffer-task-key roost--tasks))
        (inhibit-read-only t)
        (position (point))
        (places (roost--window-places)))
    (erase-buffer)
    (if (not task)
        (insert "This task has been retired or is no longer available.\n")
      (let* ((status (roost--display-status task))
             (changes (roost--changes task))
             (width (roost--task-info-width))
             (base (roost--field task 'baseRef))
             (integration (roost--field task 'integrationBranch)))
        (insert (propertize (roost--field task 'name) 'face 'roost-title) "   "
                (propertize (concat "● " status) 'face (roost--status-face (roost--attention-status task)))
                (propertize (format " for %s" (roost--elapsed (roost--field task 'updatedAt)))
                            'face 'roost-dim)
                "\n"
                (propertize (format "%s · %s · %s" (roost--host-label (roost--field task 'host))
                                    (roost--project-name task)
                                    (or (roost--field task 'agent) "claude"))
                            'face 'roost-dim)
                "\n")
        (when-let* ((reply (roost--last-message task)))
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
                (propertize "The worktree is gone; retire the task if its work is merged, or forget it"
                            'face 'roost-status-failed))
               ((not (assq 'diff task)) (propertize "Refreshing…" 'face 'roost-dim))
               ((string-empty-p changes) (propertize "No changes yet" 'face 'roost-dim))
               (t (roost--fontify-changes changes))))
        (roost--insert-changed-files task width)
        (when (> (or (roost--field task 'behind) 0) 0)
          (roost--insert-indented
           (substitute-command-keys
            (format "%s has moved on; \\<roost-task-info-mode-map>\\[roost-update] merges it into this task before you merge the task back."
                    integration))
           'roost-dim))
        (pcase status
          ((or "exited" "failed" "crashed")
           (roost--insert-indented
            (format "The agent has %s. RET shows its last output; s resumes the conversation." status)
            'roost-status-failed))
          ("offline"
           (roost--insert-indented "The host is unreachable; this is the last known state." 'roost-dim))
          ("starting"
           (cond ((equal (roost--field task 'agent) "codex")
                  (roost--insert-indented
                   "Codex reports status from its first turn. Open the terminal, review any hook or startup prompts, and enter the first prompt there; sending prompts from Emacs works after that."
                   'roost-dim))
                 ((equal (roost--attention-status task) "prompt")
                  (roost--insert-indented
                   "The agent has reported nothing yet, so it is probably waiting at a startup prompt such as folder trust. RET opens its terminal."
                   'roost-status-permission)))))
        (when-let* ((error (roost--field task 'error)))
          (roost--insert-indented (concat "Last error: " error) 'roost-status-failed))
        (roost--insert-issue task)
        (roost--insert-pull-request task)
        (when-let* ((prompt (roost--prompt-text task)))
          (roost--insert-heading "Prompt")
          (let ((preview (roost--prompt-preview prompt)))
            (if (or roost--show-full-prompt (equal preview prompt))
                (roost--insert-indented prompt)
              (roost--insert-indented preview)
              (let ((start (point)))
                (insert-text-button "Show the whole prompt" 'follow-link t 'face 'roost-field
                                    'action (lambda (_)
                                              (setq roost--show-full-prompt t)
                                              (roost--render-task-info)))
                (insert "\n")
                (put-text-property start (point) 'line-prefix "  ")))))
        (roost--insert-heading "Actions")
        (let ((width (roost--task-info-width)))
          (if (< width 72)
              (roost--insert-narrow-actions width)
            (dolist (group roost--task-actions)
              (insert "  " (propertize (format "%-9s" (car group)) 'face 'roost-dim))
              (dolist (action (cdr group))
                (roost--insert-action-button action)
                (insert " " (propertize (nth 1 action) 'face 'roost-key) "    "))
              (insert "\n")))
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
          (unless (< width 72)
            (insert "\n" (propertize (substitute-command-keys
                                      "Ready means the agent is waiting for you, not that the work is reviewed.
\\<roost-task-info-mode-map>\\[roost-task-info-refresh] refreshes · \\[roost-task-info-quit] closes")
                                     'face 'roost-dim)
                    "\n")))))
    (goto-char (min position (point-max)))
    (roost--restore-window-places places)))

(defun roost--task-info-buffer-name (task)
  "Buffer name for TASK's panel, qualified by host when names collide.
Tasks with the same name on the same host are told apart by their IDs."
  (let* ((name (roost--field task 'name))
         (host (roost--field task 'host))
         (twins (seq-filter (lambda (other) (equal (roost--field other 'name) name))
                            (roost-tasks))))
    (cond ((length< twins 2) (format "*roost: %s*" name))
          ((length< (seq-filter (lambda (other) (equal (roost--field other 'host) host)) twins) 2)
           (format "*roost: %s on %s*" name (roost--host-label host)))
          (t (format "*roost: %s on %s (%s)*" name (roost--host-label host)
                     (substring (roost--field task 'id) 0 6))))))

;;;###autoload
(defun roost-task-info (&optional task)
  "Show TASK's prompt, Git status, actions and details."
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
  "d" #'roost-new-task
  "c" #'roost-new-task
  "r" #'roost-review
  "D" #'roost-diff
  "i" #'roost-task-info
  "I" #'roost-task-panel-mode
  "b" #'roost-sidebar-mode
  "?" #'roost-task-info
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
  "n" #'roost-next-waiting
  "h" #'roost-dispatch
  "g" #'roost-refresh)

(easy-menu-define roost-dashboard-menu roost-dashboard-mode-map
  "Menu for the Roost dashboard."
  `("Roost"
    ["New task…" roost-new-task]
    ["Next task needing attention" roost-next-waiting]
    ["Switch task…" roost-switch-task]
    ["Refresh" roost-refresh]
    ["Watch hosts" roost-watch-mode :style toggle :selected roost-watch-mode]
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
                                     'face (roost--status-face (nth 2 class))))))
                   '(("awaiting permission" nil "permission")
                     ("at a startup prompt" nil "prompt")
                     ("ready" nil "ready")
                     ("seen" nil "idle")
                     ("failed" nil "failed" "crashed")
                     ("running" nil "running" "background" "starting")
                     ("stopped" nil "stopped" "exited")
                     ("offline" nil "offline"))))
     (propertize " · " 'face 'roost-dim))))

(defun roost--dashboard-layout (tasks width)
  "Column widths for TASKS in a window WIDTH columns wide.
The changes column shrinks first, then the agent column is dropped."
  (let* ((name (min 28 (max 8 (apply #'max (mapcar (lambda (task) (string-width (roost--field task 'name)))
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
         (face (roost--status-face (roost--attention-status task)))
         (cell (lambda (text size &optional cell-face)
                 (propertize (truncate-string-to-width text size nil ?\s "…") 'face cell-face)))
         (line (concat "  " (propertize "●" 'face face) " "
                       (funcall cell (roost--field task 'name) (plist-get layout :name)) "  "
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
              (propertize (truncate-string-to-width (roost--one-line (or (roost--last-message-summary task)
                                                                   (roost--prompt-text task)))
                                                    room nil nil "…")
                          'face 'roost-dim)))))

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
  "Render the dashboard from cached state, keeping point on the same task."
  (let* ((window (get-buffer-window (current-buffer) t))
         (position (if window (window-point window) (point)))
         (key (get-text-property position 'roost-task))
         (start-line (when window (line-number-at-pos (window-start window))))
         (width (if window (window-body-width window) 120))
         (tasks (roost-tasks))
         (inhibit-read-only t))
    (erase-buffer)
    (if (null tasks)
        (roost--insert-empty-dashboard)
      (let ((layout (roost--dashboard-layout tasks width)))
        (insert (roost--summary tasks) "\n")
        (dolist (group (roost--task-groups tasks))
          (let ((host (caar group)) (repo (cadar group)))
            (insert "\n" (propertize (format "%s · %s" (roost--host-label host)
                                             (file-name-nondirectory (directory-file-name (or repo "?"))))
                                     'face 'roost-heading)
                    (propertize (concat "  " (roost--abbreviate-path (or repo "") host)) 'face 'roost-dim)
                    (if (gethash host roost--errors)
                        (propertize "  unreachable; showing the last known state" 'face 'roost-status-failed)
                      "")
                    "\n")
            (dolist (task (cdr group))
              (insert (propertize (concat (roost--dashboard-row task layout width) "\n")
                                  'roost-task (roost--key task)
                                  'keymap roost--dashboard-row-map
                                  'mouse-face 'highlight
                                  'help-echo "mouse-1: open · mouse-3: actions")))))))
    (let ((target (or (and key (save-excursion
                                 (goto-char (point-min))
                                 ;; Keys are lists, so compare with `equal'.
                                 (when-let* ((match (text-property-search-forward 'roost-task key t)))
                                   (prop-match-beginning match))))
                      (text-property-not-all (point-min) (point-max) 'roost-task nil)
                      (point-min))))
      (goto-char target)
      (when window
        (set-window-start window (save-excursion (goto-char (point-min))
                                                 (forward-line (1- start-line))
                                                 (point)))
        (set-window-point window target)))))

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
  (roost-open-task))

(defun roost-dashboard-mouse-menu (event)
  "Show the actions for the task clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (popup-menu roost-task-menu event))

(defun roost--redraw ()
  "Refresh an existing dashboard and task panels without changing focus."
  (roost--note-watched-agent)
  (when-let* ((buffer (get-buffer "*roost*")))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-dashboard-mode)
        (roost--render-dashboard))))
  (when-let* ((buffer (get-buffer roost--sidebar-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-sidebar-list-mode)
        (roost--render-sidebar))))
  ;; Data that just arrived can name the task a restored workspace shows.
  (when (memq #'roost--layout-changed (default-value 'window-configuration-change-hook))
    (roost--sync-side-windows))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-task-info-mode)
        (roost--render-task-info)))))

;;;###autoload
(defun roost-status ()
  "Open the dashboard and watch configured and remembered hosts."
  (interactive)
  (let ((buffer (get-buffer-create "*roost*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-dashboard-mode) (roost-dashboard-mode)))
    (pop-to-buffer buffer)
    (roost--redraw))
  (roost-watch-mode 1)
  (roost-refresh))

;;;; Sidebar

(defvar-keymap roost-sidebar-list-mode-map
  :doc "Keys in the task sidebar."
  :parent roost-dashboard-mode-map
  "q" #'roost-sidebar-mode)

(define-derived-mode roost-sidebar-list-mode roost-dashboard-mode "Roost Sidebar"
  "A compact list of tasks, kept at the left of each frame.
Task commands act on the task at point, as in the dashboard.
\\{roost-sidebar-list-mode-map}"
  (setq-local header-line-format nil
              mode-line-format nil
              cursor-type nil
              cursor-in-non-selected-windows nil)
  (remove-hook 'window-size-change-functions #'roost--dashboard-resized t)
  (add-hook 'window-size-change-functions #'roost--sidebar-resized nil t))

(defun roost--sidebar-resized (window)
  "Reflow the sidebar after WINDOW is resized."
  (with-current-buffer (window-buffer window)
    (roost--render-sidebar)))

(defun roost--sidebar-summary (tasks)
  "Short count of TASKS waiting for you, or nil."
  (let ((waiting (seq-count (lambda (task)
                              (member (roost--attention-status task) '("permission" "prompt" "ready")))
                            tasks))
        (blocked (seq-some (lambda (task)
                             (member (roost--attention-status task) '("permission" "prompt")))
                           tasks)))
    (when (> waiting 0)
      (propertize (format "%d waiting" waiting)
                  'face (if blocked 'roost-status-permission 'roost-status-ready)))))

(defun roost--sidebar-row (task width)
  "TASK's sidebar line, within WIDTH columns."
  (let* ((current (if (roost--workspace-backend)
                      (equal (roost--workspace-name task) (roost--current-workspace))
                    (equal (roost--key task) roost--current-task)))
         (status (roost--display-status task))
         (face (roost--status-face (roost--attention-status task)))
         (room (- width 3))
         (name (roost--field task 'name))
         (label (when (>= room (+ (min (string-width name) 12) 1 (string-width status)))
                  status))
         (name (truncate-string-to-width name (if label (- room (string-width label) 1) room)
                                         nil nil "…")))
    (concat (if current (propertize "▸" 'face 'roost-heading) " ")
            (propertize "●" 'face face) " "
            (propertize name 'face (if current 'roost-heading 'default))
            (when label
              (concat (make-string (max 1 (- room (string-width name) (string-width label))) ?\s)
                      (propertize label 'face face))))))

(defun roost--render-sidebar ()
  "Render the task sidebar from cached state, keeping point on its task."
  (let* ((window (get-buffer-window (current-buffer) t))
         (width (max 12 (if window (window-body-width window) roost-sidebar-width)))
         (key (get-text-property (point) 'roost-task))
         (tasks (roost-tasks))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Roost" 'face 'roost-title)
            (if-let* ((summary (roost--sidebar-summary tasks))) (concat "  " summary) "")
            "\n")
    (if (null tasks)
        (insert "\n" (propertize (substitute-command-keys
                                  "No tasks.  \\<roost-sidebar-list-mode-map>\\[roost-new-task] starts one.")
                                 'face 'roost-dim)
                "\n")
      (dolist (group (roost--task-groups tasks))
        (let ((host (caar group)) (repo (cadar group)))
          (insert "\n" (propertize (truncate-string-to-width
                                    (format "%s · %s" (roost--host-label host)
                                            (file-name-nondirectory (directory-file-name (or repo "?"))))
                                    width nil nil "…")
                                   'face (if (gethash host roost--errors) 'roost-status-failed 'roost-dim))
                  "\n")
          (dolist (task (cdr group))
            (insert (propertize (concat (roost--sidebar-row task width) "\n")
                                'roost-task (roost--key task)
                                'keymap roost--dashboard-row-map
                                'mouse-face 'highlight
                                'help-echo (format "%s\n%s · %s\nmouse-1: open · mouse-3: actions"
                                                   (roost--field task 'name)
                                                   (roost--host-label host)
                                                   (or repo "?"))))))))
    (goto-char (or (and key (save-excursion
                              (goto-char (point-min))
                              (when-let* ((match (text-property-search-forward 'roost-task key t)))
                                (prop-match-beginning match))))
                   (point-min)))
    (when window (set-window-point window (point)))))

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
the task last used in the frame."
  (if (roost--workspace-backend)
      (when-let* ((current (roost--current-workspace)))
        (seq-find (lambda (task) (equal (roost--workspace-name task) current))
                  (roost-tasks)))
    (gethash (frame-parameter nil 'roost-task) roost--tasks)))

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

(defun roost--layout-changed ()
  "Keep Roost's side windows in step with a changed window layout.
Runs from `window-configuration-change-hook', once for each changed frame."
  (with-demoted-errors "Roost: %S" (roost--sync-side-windows)))

(defun roost--watch-layout ()
  "Keep Roost's side windows in step with the window layout from now on.
Workspace switches, splits, resizes and new frames all change the layout.
Called when Roost first shows a side window, rather than when it loads;
`roost-unload-function' stops it."
  (add-hook 'window-configuration-change-hook #'roost--layout-changed))

(defun roost--leave-side-window ()
  "Select the most recently used main window if a side window is selected.
Tasks open in the main area, never in the sidebar or the task panel."
  (when (window-parameter nil 'window-side)
    (when-let* ((window (car (sort (roost--main-windows)
                                   (lambda (a b) (> (window-use-time a) (window-use-time b)))))))
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
The panel shows the agent's latest reply, its changes and the actions.
It docks while the terminal keeps at least 80 columns, and steps aside
when a split or a narrower frame would squeeze it.  With workspaces, it
shows the task whose workspace is current.  \\<roost-task-info-mode-map>\\[roost-task-info-quit] in the panel
turns the mode off, and \\<roost-dashboard-mode-map>\\[roost-task-panel-mode] in the dashboard or sidebar
turns it back on."
  :global t
  :init-value t
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
                   "Task panel off; \\<roost-dashboard-mode-map>\\[roost-task-panel-mode] in the dashboard or sidebar turns it back on"))
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
  (when roost-sidebar-mode (roost-sidebar-mode -1))
  (when (roost--task-panel-window) (delete-window (roost--task-panel-window)))
  (remove-hook 'window-configuration-change-hook #'roost--layout-changed)
  (remove-hook 'magit-post-refresh-hook #'roost--magit-refreshed)
  (when roost-watch-mode (roost-watch-mode -1))
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
  (roost--evil-state 'roost-doctor-mode roost-evil-state))

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
                nil))))

(defun roost--doctor-line (name ok detail hint &optional path)
  "Insert one check NAME with status OK, DETAIL and HINT; PATH is a tooltip."
  (insert "  "
          (pcase ok
            ('info (propertize "·" 'face 'roost-dim))
            ('optional (propertize "–" 'face 'roost-dim))
            ('nil (propertize "✗" 'face 'roost-status-failed))
            (_ (propertize "✓" 'face 'roost-status-ready)))
          " " (format "%-16s" name)
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
              (when (car entry) (roost--doctor-line "SSH" t "connected" nil))
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
           (remhash (list host roost-state-directory) roost--installed)
           (roost--render-doctor)))))))

;;;###autoload
(defcustom roost-mode-line-count t
  "Whether `roost-watch-mode' shows waiting agents in the mode line.
The count appears in `global-mode-string', which mode lines keep even
when they hide minor modes, and only while some agent waits."
  :type 'boolean)

(defun roost--mode-line-count ()
  "\"Roost:N\" for the agents waiting for you, or nil when none are.
Agents asking permission or stuck at a startup prompt color the count."
  (let ((blocked 0) (ready 0))
    (maphash (lambda (_key task)
               (pcase (roost--attention-status task)
                 ((or "permission" "prompt") (cl-incf blocked))
                 ("ready" (cl-incf ready))))
             roost--tasks)
    (when (> (+ blocked ready) 0)
      (concat (propertize (format " Roost:%d" (+ blocked ready))
                          'face (if (> blocked 0) 'roost-status-permission 'roost-status-ready)
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

;;;###autoload
(define-minor-mode roost-watch-mode
  "Watch tasks asynchronously, retaining cached records during disconnects.
While watching, the mode line counts the agents waiting for you; see
`roost-mode-line-count'."
  :global t
  :lighter " Roost"
  (when roost--watch-timer
    (cancel-timer roost--watch-timer)
    (setq roost--watch-timer nil))
  (setq global-mode-string (delete roost--mode-line-entry (ensure-list global-mode-string)))
  (when roost-watch-mode
    (setq global-mode-string (append global-mode-string (list roost--mode-line-entry))))
  (when roost-watch-mode
    (setq roost--watch-timer
          (run-with-timer roost-watch-interval roost-watch-interval
                          (lambda () (roost-refresh t))))))

(defalias 'roost-list #'roost-switch-task)
(defalias 'roost-kill #'roost-stop)

(provide 'roost)
;;; roost.el ends here
