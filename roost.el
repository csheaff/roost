;;; roost.el --- Coding agent tasks over tmux-control -*- lexical-binding: t; -*-

;; Author: Clay Sheaff
;; Version: 0.5.0
;; Package-Requires: ((emacs "29.1"))
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
(require 'tabulated-list)
(require 'tramp)
(require 'parse-time)
(require 'button)

(declare-function tmux-control--connect-or-switch "tmux-control" (host socket session))
(declare-function tmux-control--send-command "tmux-control" (command &optional kind))
(declare-function tmux-control-select-pane "tmux-control" (&optional pane))
(declare-function tmux-control-tile "tmux-control" ())
(declare-function tmux-control--tiled-mode-p "tmux-control" ())
(declare-function tmux-control--query "tmux-control" (command callback))
(declare-function magit-status "magit-status" (&optional directory cache))
(declare-function magit-diff-working-tree "magit-diff" (&optional rev args files))
(declare-function persp-switch "perspective" (name))
(declare-function persp-kill "perspective" (name))
(declare-function persp-current-name "perspective" ())
(declare-function persp-names "perspective" ())
(declare-function persp-format-name "perspective" (name))

(defvar tmux-control-default-socket-name)
(defvar tmux-control--host)
(defvar tmux-control--socket-name)
(defvar tmux-control--active-pane)
(defvar tmux-control--window-id)
(defvar tmux-control-remote-tmux-socket-setup)
(defvar tmux-control-ssh-options)
(defvar persp-autokill-buffer-on-remove)
(defvar persp-mode nil)
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
  "Tmux session to place new task windows in, or nil for one session per repo."
  :type '(choice (const nil) string))

(defcustom roost-watch-interval 3
  "Seconds between asynchronous status refreshes."
  :type 'number)

(defcustom roost-request-timeout 60
  "Maximum seconds for a host operation."
  :type 'number)

(defcustom roost-use-perspectives t
  "Use one perspective per task when perspective.el is active."
  :type 'boolean)

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

;;;; State

(defconst roost--package-directory
  (file-name-directory (or load-file-name buffer-file-name)))

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
(defvar roost--remembered-hosts nil)
(defvar roost--hosts-loaded nil)
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

(defun roost--hosts ()
  "Configured and remembered hosts, without network I/O."
  (unless roost--hosts-loaded
    (setq roost--hosts-loaded t)
    (when (file-readable-p roost-hosts-file)
      (setq roost--remembered-hosts
            (seq-filter
             #'string-or-null-p
             (ignore-errors
               (with-temp-buffer
                 (insert-file-contents roost-hosts-file)
                 ;; Older versions wrote the local host as {}; as an alist
                 ;; that reads back as nil, which is the local host.
                 (json-parse-buffer :array-type 'list :object-type 'alist
                                    :null-object nil)))))))
  (delete-dups (append roost-hosts roost--remembered-hosts)))

(defun roost--remember-host (host)
  "Remember HOST across restarts."
  (roost--hosts)
  (unless (member host roost--remembered-hosts)
    (push host roost--remembered-hosts)
    (make-directory (file-name-directory roost-hosts-file) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file roost-hosts-file
        (insert (json-serialize (vconcat (mapcar (lambda (host) (or host :null))
                                                 roost--remembered-hosts)))))
      (set-file-modes roost-hosts-file #o600))))

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

(defun roost--python-command (host code)
  "Local argv executing Python CODE on HOST, without interpolating input."
  (if host
      (progn
        (require 'tmux-control nil t)
        (append (list "ssh" "-T" "-o" "BatchMode=yes")
                (or (bound-and-true-p tmux-control-ssh-options)
                    '("-o" "ConnectTimeout=8"))
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
  (let* ((key (roost--key task))
         (old (gethash key roost--tasks))
         (status (roost--field task 'status))
         (previous (gethash key roost--statuses))
         (new-stop (and (equal status "ready")
                        (equal (roost--field task 'lastEvent) "Stop")
                        (not (equal (roost--field task 'updatedAt)
                                    (roost--field old 'updatedAt))))))
    ;; Quiet polls skip Git; keep the statistics from the last full refresh.
    (dolist (field '(diff dirty ahead behind))
      (unless (assoc field task)
        (when (assoc field old) (push (assoc field old) task))))
    (if (member status '("retired" "forgotten"))
        (remhash key roost--tasks)
      (puthash key task roost--tasks))
    (when (and roost-notify previous
               (or (not (equal previous status)) new-stop)
               (or (not (equal previous "starting")) new-stop)
               (member status '("ready" "permission" "failed" "crashed" "exited")))
      (roost--notify (format "Roost: %s — %s" (roost--field task 'name) status)
                     (roost--host-label host)))
    (puthash key status roost--statuses)
    task))

(defun roost--apply-snapshot (host tasks)
  "Replace only HOST's cached tasks with a successful snapshot TASKS."
  (let ((keys (mapcar (lambda (task) (list host (roost--field task 'id))) tasks)))
    (maphash (lambda (key _)
               (when (and (equal (car key) host) (not (member key keys)))
                 (remhash key roost--tasks)
                 (remhash key roost--statuses)))
             roost--tasks)
    (mapc (lambda (task) (roost--cache-task host task)) tasks)
    (remhash host roost--errors)))

(defvar roost--full-refresh-pending (make-hash-table :test 'equal)
  "Hosts whose full refresh was requested while another request was in flight.")
(defvar roost--failures (make-hash-table :test 'equal)
  "Consecutive refresh failures per host, as (COUNT . RETRY-AFTER).")

(defun roost--refresh-host (host quiet)
  "Refresh HOST asynchronously.  QUIET skips Git statistics."
  (if (gethash host roost--refreshing)
      ;; Run the requested full refresh once the in-flight poll returns.
      (unless quiet (puthash host t roost--full-refresh-pending))
    (puthash host t roost--refreshing)
    (let ((revision (gethash host roost--revisions 0))
          (finish (lambda ()
                    (remhash host roost--refreshing)
                    (when (gethash host roost--full-refresh-pending)
                      (remhash host roost--full-refresh-pending)
                      (roost--refresh-host host nil)))))
      (roost--request
       host "list" (list (cons 'full (if quiet :false t)))
       (lambda (tasks)
         (remhash host roost--failures)
         ;; A newer mutation must win over a stale list reply.
         (when (= revision (gethash host roost--revisions 0))
           (roost--apply-snapshot host tasks))
         (roost--redraw)
         (funcall finish))
       (lambda (err)
         (unless (equal err (gethash host roost--errors))
           (message "Roost %s: %s" (roost--host-label host) err))
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

(defun roost--read-task (prompt)
  "Choose a cached task with PROMPT."
  (let* ((tasks (roost-tasks))
         (choices
          (mapcar (lambda (task)
                    (cons (format "%s / %s / %s [%s] %s"
                                  (roost--host-label (roost--field task 'host))
                                  (roost--project-name task) (roost--field task 'name)
                                  (roost--field task 'status) (roost--field task 'id))
                          task))
                  tasks)))
    (unless tasks
      (user-error "No cached tasks; open Roost and refresh, or create one"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun roost--task-at-point ()
  "Task selected in the dashboard, terminal, or current workspace."
  (cond
   ((derived-mode-p 'roost-dashboard-mode)
    (gethash (tabulated-list-get-id) roost--tasks))
   (roost--buffer-task-key
    (or (gethash roost--buffer-task-key roost--tasks)
        (user-error "This task has been retired or is unavailable")))
   (t
    (let ((tasks (roost-tasks))
          (perspective-active (and roost-use-perspectives (bound-and-true-p persp-mode)
                                   (fboundp 'persp-current-name))))
      (or
       (and (bound-and-true-p tmux-control--active-pane)
            (seq-find (lambda (task)
                        (and (equal (roost--field task 'host) tmux-control--host)
                             (equal (roost--field task 'socket) tmux-control--socket-name)
                             (member tmux-control--active-pane
                                     (list (roost--field task 'paneId)
                                           (roost--field task 'shellPaneId)))))
                      tasks))
       ;; String comparisons avoid opening a remote connection just to infer context.
       (condition-case nil
           (let* ((directory (file-name-as-directory (expand-file-name default-directory)))
                  (host (roost--directory-host directory))
                  (local (file-local-name directory)))
             (seq-find (lambda (task)
                         (and (equal host (roost--field task 'host))
                              (string-prefix-p
                               (file-name-as-directory (roost--field task 'worktree))
                               local)))
                       tasks))
         (user-error nil))
       (and perspective-active
            (seq-find (lambda (task)
                        (equal (persp-current-name) (roost--perspective-name task)))
                      tasks))
       ;; An unrelated perspective or file must not silently target the last task.
       (and (not perspective-active) (not buffer-file-name)
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

(with-eval-after-load 'perspective
  (unless (advice-member-p #'roost--compact-perspective-mode-line 'persp-mode-line)
    (advice-add 'persp-mode-line :filter-return #'roost--compact-perspective-mode-line)))

(defun roost--activate-workspace (task)
  "Restore TASK's saved window arrangement when perspective.el is active."
  (when (and roost-use-perspectives (bound-and-true-p persp-mode) (fboundp 'persp-switch))
    (persp-switch (roost--perspective-name task)))
  (setq roost--current-task (roost--key task)))

;;;; Opening tasks

(defun roost--display-task (task &optional target-pane)
  "Display TASK after ownership validation, selecting TARGET-PANE if supplied."
  (require 'tmux-control)
  (roost--activate-workspace task)
  ;; Reuse the saved terminal window instead of replacing its neighboring
  ;; code or Magit window when that happened to be selected on departure.
  (when-let* ((window
               (seq-find (lambda (window)
                           (with-current-buffer (window-buffer window)
                             (and (bound-and-true-p tmux-control--window-id)
                                  (equal tmux-control--host (roost--field task 'host))
                                  (equal tmux-control--socket-name (roost--field task 'socket))
                                  (equal tmux-control--window-id (roost--field task 'windowId)))))
                         (window-list))))
    (select-window window))
  (tmux-control--connect-or-switch (roost--field task 'host) (roost--field task 'socket)
                                   (roost--field task 'session))
  ;; Explicit window hop also works before the pane map arrives on connect.
  (let ((window (roost--field task 'windowId))
        (pane (or target-pane (roost--field task 'paneId))))
    (unless (and (stringp window) (string-match-p "\\`@[0-9]+\\'" window)
                 (stringp pane) (string-match-p "\\`%[0-9]+\\'" pane))
      (user-error "Invalid tmux target"))
    (with-current-buffer (window-buffer (selected-window))
      (tmux-control--send-command (format "select-window -t %s" window))
      (tmux-control-select-pane pane))))

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

(defun roost--read-new-task ()
  "Read creation arguments with an independent task as the default.
A prefix argument instead defaults to forking the current task's committed HEAD."
  (let* ((task (roost--task-at-point))
         (source (if task
                     (if current-prefix-arg
                         (roost--remote-directory task)
                       (roost--remote-directory
                        (cons (cons 'worktree (roost--field task 'repo)) task)))
                   default-directory))
         (directory (read-directory-name "Project checkout (local or TRAMP): " source nil t))
         (name (read-string "Task name: "))
         (agent (completing-read "Agent: " roost--agents nil t nil nil roost-default-agent)))
    (list directory name
          (let ((ref (read-string "Start from ref (empty = primary checkout branch): "
                                  nil nil (when current-prefix-arg "HEAD"))))
            (unless (string-empty-p (string-trim ref)) (string-trim ref)))
          (read-string "Initial prompt (optional): ")
          agent)))

;;;###autoload
(defun roost-new-task (directory name &optional base prompt agent)
  "Create an AGENT task NAME in DIRECTORY from BASE, with optional PROMPT.
Nil AGENT uses `roost-default-agent'.
DIRECTORY may be a TRAMP path.  Nil BASE uses the primary checkout's current
branch, even when DIRECTORY is a task worktree.  Explicit HEAD uses DIRECTORY.
Interactively, a prefix argument defaults to forking the current task."
  (interactive (roost--read-new-task))
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
     (list (cons 'directory (file-local-name directory))
           (cons 'name name)
           (cons 'base base)
           (cons 'agent agent)
           (cons 'prompt (unless (string-empty-p (or prompt "")) prompt))
           (cons 'command (vconcat (or (cdr (assoc agent roost-agent-commands))
                                       (and (equal agent "claude") roost-claude-command)
                                       (list agent))))
           (cons 'setup setup)
           (cons 'branchPrefix roost-branch-prefix)
           (cons 'socket (or roost-socket-name
                             (bound-and-true-p tmux-control-default-socket-name)
                             "main"))
           (cons 'session roost-session-name))
     (lambda (task)
       (cl-incf (gethash host roost--revisions 0))
       (roost--remember-host host)
       (setq task (roost--cache-task host task))
       (roost-watch-mode 1)
       (roost--redraw)
       (roost-open-task task)
       (message "Roost created %s on %s from %s; integrates into %s"
                name (roost--host-label host)
                (roost--field task 'baseRef) (roost--field task 'integrationBranch))))
    (message "Roost: creating %s…" name)))

;;;; Task commands

(defun roost--act (task action &optional parameters callback)
  "Run ACTION on TASK with PARAMETERS, then CALLBACK with the updated task."
  (let ((host (roost--field task 'host)))
    (roost--request host action (cons (cons 'id (roost--field task 'id)) parameters)
                    (lambda (updated)
                      (cl-incf (gethash host roost--revisions 0))
                      (setq updated (roost--cache-task host updated))
                      (roost--redraw)
                      (message "Roost %s: %s" (roost--field task 'name) action)
                      (when callback (funcall callback updated))))))

;;;###autoload
(defun roost-resume (&optional task)
  "Restart TASK, resuming its recorded agent conversation."
  (interactive)
  (roost--act (roost--choose task) "resume" nil #'roost-open-task))

;;;###autoload
(defun roost-send (&optional task text)
  "Send TEXT as a literal pasted prompt to TASK's agent pane."
  (interactive)
  (setq task (roost--choose task)
        text (or text (read-string (format "Send to %s: " (roost--field task 'name)))))
  (roost--act task "send" (list (cons 'text text))))

;;;###autoload
(defun roost-send-region (start end)
  "Send region START to END with file and line context to a chosen task."
  (interactive "r")
  (let ((last (if (and (> end start) (eq (char-before end) ?\n)) (1- end) end)))
    (roost-send (roost--read-task "Send region to task: ")
                (format "%s:%d-%d\n\n%s"
                        (if buffer-file-name (file-local-name buffer-file-name) (buffer-name))
                        (line-number-at-pos start) (line-number-at-pos last)
                        (buffer-substring-no-properties start end)))))

;;;###autoload
(defun roost-review (&optional task)
  "Open Magit on TASK's worktree, through TRAMP for remote tasks."
  (interactive)
  (setq task (roost--choose task))
  (roost--activate-workspace task)
  (if (require 'magit nil t)
      (magit-status (roost--remote-directory task))
    (dired (roost--remote-directory task))))

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
                      (unless (tmux-control--tiled-mode-p) (tmux-control-tile))
                      (roost--focus-shell updated generation)))))))

(defun roost--focus-shell (task generation)
  "Focus TASK's shell after queued tiling replies, unless GENERATION changed."
  (let ((frame (selected-frame)))
    (tmux-control--query
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
                       (and (equal (bound-and-true-p tmux-control--host)
                                   (roost--field task 'host))
                            (equal (bound-and-true-p tmux-control--socket-name)
                                   (roost--field task 'socket))
                            (member (bound-and-true-p tmux-control--active-pane)
                                    (list (roost--field task 'paneId)
                                          (roost--field task 'shellPaneId)))))
                     (or (not (and roost-use-perspectives (bound-and-true-p persp-mode)))
                         (equal (persp-current-name) (roost--perspective-name task))))
            (when-let* ((window
                         (seq-find
                          (lambda (window)
                            (with-current-buffer (window-buffer window)
                              (and (equal (bound-and-true-p tmux-control--host)
                                          (roost--field task 'host))
                                   (equal (bound-and-true-p tmux-control--socket-name)
                                          (roost--field task 'socket))
                                   (equal (bound-and-true-p tmux-control--active-pane)
                                          (roost--field task 'shellPaneId)))))
                          (window-list frame))))
              (select-window window)))))))))

;;;###autoload
(defun roost-diff (&optional task)
  "Review TASK's tracked changes against its recorded starting commit."
  (interactive)
  (setq task (roost--choose task))
  (require 'magit)
  (roost--activate-workspace task)
  (let ((default-directory (roost--remote-directory task)))
    (magit-diff-working-tree (roost--field task 'baseCommit))))

;;;###autoload
(defun roost-stop (&optional task)
  "Stop TASK's window, retaining its worktree, branch and conversation."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Stop %s's window and its processes? Work is kept. "
                             (roost--field task 'name)))
    (roost--act task "stop")))

;;;###autoload
(defun roost-retire (&optional task)
  "Remove TASK's clean, merged worktree and branch, then stop its window."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Retire %s? Its clean, merged worktree and branch will be removed. "
                             (roost--field task 'name)))
    (roost--act task "retire" nil #'roost--retired-workspace)))

;;;###autoload
(defun roost-merge-retire (&optional task)
  "Merge TASK's committed work into its recorded integration branch and retire.
Dirty worktrees are refused; review and commit in Magit first."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Merge committed work from %s and retire it? "
                             (roost--field task 'name)))
    (roost--act task "merge" nil #'roost--retired-workspace)))

;;;###autoload
(defun roost-forget (&optional task)
  "Drop TASK's record from Roost without touching its worktree or branch.
For tasks Roost can no longer retire, such as one whose repository moved.
A running agent must be stopped first."
  (interactive)
  (setq task (roost--choose task))
  (when (yes-or-no-p (format "Forget %s? Roost drops its record; its worktree and branch are left as they are. "
                             (roost--field task 'name)))
    (roost--act task "forget" nil
                (lambda (forgotten)
                  (roost--retired-workspace forgotten)
                  (when-let* ((left (roost--field forgotten 'leftBehind)))
                    (message "Forgot %s; left in place: %s"
                             (roost--field task 'name) (string-join left ", ")))))))

(defun roost--retired-workspace (task)
  "Remove TASK's perspective, retaining buffers."
  (when (and roost-use-perspectives (bound-and-true-p persp-mode) (fboundp 'persp-kill))
    (let ((persp-autokill-buffer-on-remove nil))
      (persp-kill (roost--perspective-name task)))))

;;;###autoload
(defun roost-next-waiting ()
  "Cycle through live tasks whose agent session needs attention."
  (interactive)
  (let* ((waiting (seq-filter (lambda (task)
                                (and (not (gethash (roost--field task 'host) roost--errors))
                                     (member (roost--field task 'status) '("ready" "permission"))))
                              (roost-tasks)))
         (keys (mapcar #'roost--key waiting))
         (tail (member roost--current-task keys))
         (key (or (cadr tail) (car keys))))
    (unless key (user-error "No live tasks need attention"))
    (roost-open-task (gethash key roost--tasks))))

(defun roost--project-name (task)
  "Short primary repository name for TASK."
  (file-name-nondirectory (directory-file-name (or (roost--field task 'repo) "unknown"))))

;;;; Task panel

(defvar-keymap roost-task-info-mode-map
  :doc "Actions on the task shown in this buffer."
  "RET" #'roost-open-task
  "r" #'roost-review
  "D" #'roost-diff
  "f" #'roost-files
  "t" #'roost-shell
  "e" #'roost-send
  "s" #'roost-resume
  "k" #'roost-stop
  "x" #'roost-retire
  "m" #'roost-merge-retire
  "X" #'roost-forget
  "g" #'roost-refresh)

(define-derived-mode roost-task-info-mode special-mode "Roost Task"
  "Task details and lifecycle commands.  Status is the last cached observation.")

(defun roost--render-task-info ()
  "Update the current task panel from the cache, without changing focus."
  (let ((task (gethash roost--buffer-task-key roost--tasks))
        (inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (if (not task)
        (insert "This task has been retired or is unavailable.\n")
      (insert (format "%s / %s / %s\n\n"
                      (roost--host-label (roost--field task 'host))
                      (roost--project-name task) (roost--field task 'name)))
      (dolist (entry `(("Agent" . ,(or (roost--field task 'agent) "claude"))
                       ("Status (cached)" . ,(if (gethash (roost--field task 'host) roost--errors)
                                                 "offline"
                                               (roost--field task 'status)))
                       ("Project" . ,(roost--field task 'repo))
                       ("Worktree" . ,(roost--field task 'worktree))
                       ("Task branch" . ,(roost--field task 'branch))
                       ("Started from" . ,(roost--field task 'baseRef))
                       ("Integrates into" . ,(roost--field task 'integrationBranch))
                       ("Tmux session" . ,(roost--field task 'session))))
        (insert (format "%-18s %s\n" (car entry) (or (cdr entry) "unknown"))))
      (when-let* ((error (roost--field task 'error)))
        (insert "\nLast error: " error "\n"))
      (when (and (equal (roost--field task 'agent) "codex")
                 (equal (roost--field task 'status) "starting"))
        (insert "\nOpen the agent terminal, review any hooks/startup prompts, and enter the\n"
                "first prompt there. Codex starts status events on the first turn, including\n"
                "after resume; Send prompt becomes available after that.\n"))
      (insert "\n")
      (dolist (action '(("RET  Agent" . roost-open-task)
                        ("t  Shell beside agent" . roost-shell)
                        ("f  Files" . roost-files)
                        ("r  Review / commit in Magit" . roost-review)
                        ("D  Diff since creation" . roost-diff)
                        ("e  Send prompt" . roost-send)
                        ("k  Stop; keep work" . roost-stop)
                        ("s  Resume conversation" . roost-resume)
                        ("m  Merge committed work and retire" . roost-merge-retire)
                        ("x  Retire after a manual merge" . roost-retire)
                        ("X  Forget; keep worktree and branch" . roost-forget)))
        (insert-text-button (car action) 'follow-link t 'roost-command (cdr action)
                            'action (lambda (button)
                                      (call-interactively (button-get button 'roost-command))))
        (insert "\n"))
      (insert "\nFinished? Review and commit with r, then merge and retire with m.\n"
              "Both checkouts must be clean. Stop active work first with k.\n"
              "Ready means the agent awaits input; it does not mean reviewed or complete.\n\n"
              "g refreshes status; q closes this panel.\n"))
    (goto-char (min position (point-max)))))

;;;###autoload
(defun roost-task-info (&optional task)
  "Show TASK's project, starting branch, integration target and actions."
  (interactive)
  (setq task (roost--choose task))
  (let ((buffer (get-buffer-create
                 (format "*roost task %s:%s*" (roost--host-label (roost--field task 'host))
                         (roost--field task 'id)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'roost-task-info-mode) (roost-task-info-mode))
      (setq roost--buffer-task-key (roost--key task))
      (roost--render-task-info))
    (pop-to-buffer buffer)))

;;;; Dashboard

(defun roost--status-face (status)
  "Face for STATUS."
  (pcase status
    ((or "permission" "ready") 'warning)
    ((or "failed" "crashed" "offline") 'error)
    ((or "running" "background") 'font-lock-keyword-face)
    (_ 'shadow)))

(defun roost--elapsed (timestamp)
  "Format time since TIMESTAMP."
  (if (not timestamp)
      "?"
    (condition-case nil
        (let ((seconds (floor (max 0 (- (float-time) (float-time (date-to-time timestamp)))))))
          (cond ((< seconds 60) (format "%ds" seconds))
                ((< seconds 3600) (format "%dm" (/ seconds 60)))
                (t (format "%dh%02dm" (/ seconds 3600) (/ (mod seconds 3600) 60)))))
      (error "?"))))

(defun roost--changes (task)
  "Compact Git summary for TASK from the last full refresh."
  (let* ((diff (or (roost--field task 'diff) ""))
         (count (lambda (pattern)
                  (if (string-match (concat "\\([0-9]+\\) " pattern) diff)
                      (string-to-number (match-string 1 diff))
                    0)))
         (files (funcall count "files? changed"))
         (ahead (or (roost--field task 'ahead) 0))
         (behind (or (roost--field task 'behind) 0)))
    (string-join
     (delq nil (list (when (> files 0)
                       (format "%d file%s +%d −%d" files (if (= files 1) "" "s")
                               (funcall count "insertions?") (funcall count "deletions?")))
                     (when (roost--field task 'dirty) "uncommitted")
                     (when (> ahead 0) (format "%d ahead" ahead))
                     (when (> behind 0) (format "%d behind" behind))))
     " · ")))

(defun roost--one-line (string)
  "STRING with line breaks and tabs collapsed, for a table cell."
  (replace-regexp-in-string "[\n\r\t]+" " " (or string "")))

(defun roost--entries ()
  "Dashboard rows, entirely from cached state."
  (mapcar (lambda (task)
            (let* ((host (roost--field task 'host))
                   (status (if (gethash host roost--errors) "offline" (roost--field task 'status))))
              (list (roost--key task)
                    (vector (roost--host-label host)
                            (roost--field task 'name)
                            (or (roost--field task 'agent) "claude")
                            (propertize status 'face (roost--status-face status))
                            (roost--elapsed (roost--field task 'updatedAt))
                            (roost--project-name task)
                            (roost--changes task)
                            (roost--field task 'branch)
                            (roost--one-line (roost--field task 'task))))))
          (roost-tasks)))

(defvar-keymap roost-dashboard-mode-map
  :doc "Task dashboard commands."
  "RET" #'roost-open-task
  "c" #'roost-new-task
  "d" #'roost-new-task
  "r" #'roost-review
  "D" #'roost-diff
  "?" #'roost-task-info
  "i" #'roost-task-info
  "f" #'roost-files
  "t" #'roost-shell
  "e" #'roost-send
  "s" #'roost-resume
  "k" #'roost-stop
  "x" #'roost-retire
  "m" #'roost-merge-retire
  "X" #'roost-forget
  "n" #'roost-next-waiting
  "g" #'roost-refresh)

(defun roost--dashboard-display-settings ()
  "Keep table columns intact after global minor modes enable themselves."
  (when (derived-mode-p 'roost-dashboard-mode)
    (visual-line-mode -1)
    (display-line-numbers-mode -1)
    (setq truncate-lines t)))

(define-derived-mode roost-dashboard-mode tabulated-list-mode "Roost"
  "Tasks across hosts.  All refreshes are asynchronous."
  (setq tabulated-list-format [("Host" 14 t) ("Task" 24 t) ("Agent" 8 t) ("Status" 12 t)
                               ("Since" 8 t) ("Project" 20 t) ("Changes" 30 t)
                               ("Branch" 36 t) ("Prompt" 0 nil)]
        tabulated-list-use-header-line nil
        truncate-lines t
        display-line-numbers nil
        tabulated-list-entries #'roost--entries)
  (add-hook 'after-change-major-mode-hook #'roost--dashboard-display-settings 90 t)
  (tabulated-list-init-header))

(defun roost--redraw ()
  "Refresh an existing dashboard and task panels without changing focus."
  (when-let* ((buffer (get-buffer "*roost*")))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-dashboard-mode)
        (setq header-line-format
              (concat " RET open · c new · ? task/actions · t shell · r Magit · m merge/retire · g refresh"
                      (when (> (hash-table-count roost--errors) 0)
                        "  — host unavailable; last state retained")))
        (tabulated-list-print t))))
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

;;;###autoload
(define-minor-mode roost-watch-mode
  "Watch tasks asynchronously, retaining cached records during disconnects."
  :global t
  :lighter " Roost"
  (when roost--watch-timer
    (cancel-timer roost--watch-timer)
    (setq roost--watch-timer nil))
  (when roost-watch-mode
    (setq roost--watch-timer
          (run-with-timer roost-watch-interval roost-watch-interval
                          (lambda () (roost-refresh t))))))

(defalias 'roost-list #'roost-switch-task)
(defalias 'roost-kill #'roost-stop)
(defalias 'roost-dispatch #'roost-new-task)

(provide 'roost)
;;; roost.el ends here
