;;; roost.el --- Remote Claude tasks over tmux-control -*- lexical-binding: t; -*-
;; Author: Clay Sheaff
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;; URL: https://github.com/csheaff/roost
;;; Commentary:
;; Claude runs in tmux on the task's host. Roost owns task lifecycle and
;; observational Claude hooks; tmux-control owns rendering. JSON RPC over SSH
;; is asynchronous. Files and Magit use TRAMP. Global Claude settings are never
;; changed, and stopping Claude never removes its work.
;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'seq)
(require 'tabulated-list)
(require 'tramp)
(require 'parse-time)
(declare-function tmux-control--connect-or-switch "tmux-control" (host socket session))
(declare-function tmux-control--send-command "tmux-control" (command &optional kind))
(declare-function tmux-control-select-pane "tmux-control" (&optional pane))
(declare-function magit-status "magit-status" (&optional directory cache))
(declare-function magit-diff-working-tree "magit-diff" (&optional rev args files))
(declare-function persp-switch "perspective" (name))
(declare-function persp-kill "perspective" (name))
(defvar tmux-control-default-socket-name)
(defvar tmux-control--host)
(defvar tmux-control--socket-name)
(defvar tmux-control--active-pane)
(defvar tmux-control--window-id)
(defvar tmux-control-remote-tmux-socket-setup)
(defvar tmux-control-ssh-options)
(defvar persp-autokill-buffer-on-remove)
(defgroup roost nil "Claude tasks in persistent local or remote tmux." :group 'tools)
(defcustom roost-hosts '(nil)
  "SSH hosts to monitor. Nil means local. Task hosts are also remembered."
  :type '(repeat (choice (const :tag "Local" nil) string)))
(defcustom roost-state-directory "~/.local/share/roost"
  "Host-side directory for task records, helper, settings, and worktrees." :type 'string)
(defcustom roost-claude-command '("claude")
  "Claude executable and extra arguments, evaluated on the task host." :type '(repeat string))
(defcustom roost-setup-command nil
  "Optional project setup shell command, run before Claude in new worktrees.
May be set directory-locally. Not rerun on resume."
  :type '(choice (const nil) string))
(defcustom roost-socket-name nil
  "Tmux socket, or nil to use tmux-control's configured default."
  :type '(choice (const nil) string))
(defcustom roost-session-name nil
  "Tmux session to place new task windows in, or nil for one session per repo."
  :type '(choice (const nil) string))
(defcustom roost-watch-interval 3 "Seconds between asynchronous status refreshes." :type 'number)
(defcustom roost-request-timeout 60 "Maximum seconds for a host operation." :type 'number)
(defcustom roost-use-perspectives t
  "Use one perspective per task when perspective.el is active." :type 'boolean)
(defcustom roost-notify t "Notify on transitions requiring attention." :type 'boolean)
(defcustom roost-notify-function nil
  "Optional function of TITLE and BODY to display notifications."
  :type '(choice (const nil) function))
(defcustom roost-hosts-file (locate-user-emacs-file "roost/hosts.json")
  "Local file remembering hosts used by Roost." :type 'file)
(defconst roost--package-directory (file-name-directory (or load-file-name buffer-file-name)))
(defvar roost--tasks (make-hash-table :test 'equal))
(defvar roost--installed (make-hash-table :test 'equal))
(defvar roost--refreshing (make-hash-table :test 'equal))
(defvar roost--revisions (make-hash-table :test 'equal))
(defvar roost--errors (make-hash-table :test 'equal))
(defvar roost--statuses (make-hash-table :test 'equal))
(defvar roost--remembered-hosts nil)
(defvar roost--hosts-loaded nil)
(defvar roost--current-task nil)
(defvar roost--watch-timer nil)
(defvar roost--requests nil)
(defvar roost--open-generation 0)

(defun roost--host-label (host) "Display label for HOST." (or host "local"))

(defun roost--key (task) "Qualified identity of TASK." (list (alist-get 'host task) (alist-get 'id task)))

(defun roost--field (task field) "Read FIELD from TASK." (alist-get field task))

(defun roost--hosts ()
  "Configured and remembered hosts, without network I/O."
  (unless roost--hosts-loaded
    (setq roost--hosts-loaded t)
    (when (file-readable-p roost-hosts-file)
      (setq roost--remembered-hosts
            (ignore-errors (with-temp-buffer (insert-file-contents roost-hosts-file)
                                             (json-parse-buffer :array-type 'list :null-object nil))))))
  (delete-dups (append roost-hosts roost--remembered-hosts)))

(defun roost--remember-host (host)
  "Remember HOST across restarts."
  (roost--hosts)
  (unless (member host roost--remembered-hosts)
    (push host roost--remembered-hosts)
    (make-directory (file-name-directory roost-hosts-file) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file roost-hosts-file (insert (json-serialize (vconcat roost--remembered-hosts))))
      (set-file-modes roost-hosts-file #o600))))

(defun roost--directory-host (directory)
  "SSH destination for DIRECTORY, or nil for local."
  (when (file-remote-p directory)
    (let* ((parts (tramp-dissect-file-name directory)) (host (tramp-file-name-host parts))
           (user (tramp-file-name-user parts)) (port (tramp-file-name-port parts)))
      (when (or port (tramp-file-name-hop parts))
        (user-error "Use an SSH config alias for custom ports or jump hosts"))
      (if user (concat user "@" host) host))))

(defun roost--remote-directory (task)
  "TASK's worktree as a local or configured TRAMP path."
  (let ((host (roost--field task 'host)) (path (roost--field task 'worktree)))
    (if (not host) (file-name-as-directory path)
      (let* ((parts (split-string host "@")) (user (and (> (length parts) 1) (car parts)))
             (bare (car (last parts)))
             (method (substring-no-properties (tramp-find-method nil user bare))))
        (concat "/" method ":" host ":" (file-name-as-directory path))))))

(defun roost--helper ()
  "Return (VERSIONED-FILENAME . SOURCE) for the host helper."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "scripts/roost_remote.py" roost--package-directory))
    (cons (concat "remote-" (substring (secure-hash 'sha256 (current-buffer)) 0 16) ".py") (buffer-string))))

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
  (json-parse-string (car (last (split-string output "\n" t "[ \t\r]+")))
                     :object-type 'alist :array-type 'list :null-object nil :false-object nil))

(defun roost--run (host code input success failure)
  "Execute CODE asynchronously on HOST with INPUT and SUCCESS/FAILURE callbacks."
  (let* ((buffer (generate-new-buffer " *roost-rpc*")) (errors (generate-new-buffer " *roost-rpc-errors*"))
         (default-directory temporary-file-directory) process timer finished)
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name "roost-rpc" :buffer buffer :stderr errors :noquery t
                 :coding 'utf-8-unix :connection-type 'pipe :command (roost--python-command host code)
                 :sentinel
                 (lambda (proc _event)
                   (when (and (memq (process-status proc) '(exit signal)) (not finished))
                     (setq finished t roost--requests (delq proc roost--requests))
                     (when timer (cancel-timer timer))
                     (unwind-protect
                         (let ((stdout (with-current-buffer buffer (buffer-string)))
                               (stderr (with-current-buffer errors (string-trim (buffer-string)))))
                           (condition-case parse-error
                               (if (= (process-exit-status proc) 0)
                                   (let ((response (roost--decode-response stdout)))
                                     (if (alist-get 'ok response) (funcall success (alist-get 'result response))
                                       (funcall failure (or (alist-get 'error response) "Host operation failed"))))
                                 (funcall failure (if (string-empty-p stderr) "Host operation failed or timed out" stderr)))
                             (error (funcall failure (error-message-string parse-error)))))
                       (kill-buffer buffer) (kill-buffer errors))))))
          (push process roost--requests)
          (setq timer (run-at-time roost-request-timeout nil
                                   (lambda () (when (process-live-p process) (delete-process process)))))
          (process-send-string process input) (process-send-eof process))
      (error (when (and process (process-live-p process)) (delete-process process))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (when (buffer-live-p errors) (kill-buffer errors))
             (funcall failure (error-message-string err))))))

(defun roost--request (host action parameters success &optional failure)
  "Run ACTION with PARAMETERS on HOST, installing the versioned helper as needed."
  (let* ((helper (roost--helper)) (filename (car helper))
         (root roost-state-directory) (installation-key (list host root))
         (failure (or failure (lambda (err) (message "Roost %s: %s" (roost--host-label host) err))))
         (invoke
          (lambda ()
            (roost--run host
                       (format "import os,runpy,sys; p=os.path.join(os.path.expanduser(%s),%s); sys.argv=[p,'rpc']; runpy.run_path(p,run_name='__main__')"
                               (json-serialize root) (json-serialize filename))
                       (json-serialize (append (list (cons 'action action) (cons 'root root)) parameters))
                       success failure))))
    (if (equal (gethash installation-key roost--installed) filename) (funcall invoke)
      (roost--run host
                 (format "import os,sys,tempfile,json\nr=os.path.expanduser(%s)\nos.makedirs(r,mode=0o700,exist_ok=True)\np=os.path.join(r,%s)\nfd,t=tempfile.mkstemp(dir=r)\nwith os.fdopen(fd,'wb') as f: f.write(sys.stdin.buffer.read())\nos.chmod(t,0o700)\nos.replace(t,p)\nprint(json.dumps({'ok':True}))"
                         (json-serialize root) (json-serialize filename))
                 (cdr helper) (lambda (_) (puthash installation-key filename roost--installed) (funcall invoke)) failure))))

(defun roost--notify (title body)
  "Display notification TITLE with BODY."
  (cond ((functionp roost-notify-function) (funcall roost-notify-function title body))
        ((executable-find "terminal-notifier") (call-process "terminal-notifier" nil 0 nil "-title" title "-message" body))
        ((eq system-type 'darwin) (call-process "osascript" nil 0 nil "-e"
                                               (format "display notification %S with title %S" body title)))
        ((fboundp 'notifications-notify) (notifications-notify :title title :body body))
        (t (message "%s: %s" title body))))

(defun roost--cache-task (host task)
  "Cache TASK from HOST and notify only on attention transitions."
  (setf (alist-get 'host task) host)
  (let* ((key (roost--key task)) (old (gethash key roost--tasks))
         (status (roost--field task 'status)) (previous (gethash key roost--statuses))
         (new-stop (and (equal status "ready") (equal (roost--field task 'lastEvent) "Stop")
                        (not (equal (roost--field task 'updatedAt) (roost--field old 'updatedAt))))))
    (dolist (field '(diff dirty))
      (unless (assoc field task) (when (assoc field old) (push (assoc field old) task))))
    (if (equal status "retired") (remhash key roost--tasks) (puthash key task roost--tasks))
    (when (and roost-notify previous (or (not (equal previous status)) new-stop)
               (or (not (equal previous "starting")) new-stop)
               (member status '("ready" "permission" "failed" "crashed" "exited")))
      (roost--notify (format "Roost: %s — %s" (roost--field task 'name) status) (roost--host-label host)))
    (puthash key status roost--statuses) task))

(defun roost--apply-snapshot (host tasks)
  "Replace only HOST's cached tasks with a successful snapshot."
  (let ((keys (mapcar (lambda (task) (list host (roost--field task 'id))) tasks)))
    (maphash (lambda (key _) (when (and (equal (car key) host) (not (member key keys)))
                              (remhash key roost--tasks) (remhash key roost--statuses))) roost--tasks)
    (mapc (lambda (task) (roost--cache-task host task)) tasks) (remhash host roost--errors)))

(defun roost-refresh (&optional quiet)
  "Refresh hosts asynchronously. QUIET skips expensive Git diffstats."
  (interactive)
  (dolist (host (roost--hosts))
    (unless (gethash host roost--refreshing)
      (puthash host t roost--refreshing)
      (let ((host host) (revision (gethash host roost--revisions 0)))
        (roost--request host "list" (list (cons 'full (if quiet :false t)))
                       (lambda (tasks)
                         (remhash host roost--refreshing)
                         ;; A newer mutation must win over a stale list reply.
                         (when (= revision (gethash host roost--revisions 0)) (roost--apply-snapshot host tasks))
                         (roost--redraw))
                       (lambda (err)
                         (remhash host roost--refreshing)
                         (unless (equal err (gethash host roost--errors)) (message "Roost %s: %s" (roost--host-label host) err))
                         (puthash host err roost--errors)
                         (remhash (list host roost-state-directory) roost--installed) (roost--redraw)))))))

(defun roost-tasks ()
  "Cached tasks across hosts, without network I/O."
  (let (tasks)
    (maphash (lambda (_ task) (push task tasks)) roost--tasks)
    (sort tasks (lambda (a b) (string-lessp (concat (roost--host-label (roost--field a 'host)) (roost--field a 'name))
                                           (concat (roost--host-label (roost--field b 'host)) (roost--field b 'name)))))))

(defun roost--read-task (prompt)
  "Choose a cached task with PROMPT."
  (let* ((tasks (roost-tasks))
         (choices (mapcar (lambda (task) (cons (format "%s / %s [%s] %s" (roost--host-label (roost--field task 'host))
                                                      (roost--field task 'name) (roost--field task 'status) (roost--field task 'id)) task)) tasks)))
    (unless tasks (user-error "No cached tasks; open Roost and refresh, or create one"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun roost--task-at-point ()
  "Task selected in the dashboard, terminal, or current workspace."
  (if (derived-mode-p 'roost-dashboard-mode)
      (gethash (tabulated-list-get-id) roost--tasks)
    (or
      (and (boundp 'tmux-control--active-pane) tmux-control--active-pane
           (seq-find (lambda (task) (and (equal (roost--field task 'host) tmux-control--host)
                                         (equal (roost--field task 'socket) tmux-control--socket-name)
                                         (equal (roost--field task 'paneId) tmux-control--active-pane))) (roost-tasks)))
      (gethash roost--current-task roost--tasks))))

(defun roost--choose (&optional task)
  "Choose TASK or infer it from context." (or task (roost--task-at-point) (roost--read-task "Task: ")))

(defun roost--perspective-name (task)
  "Unique workspace name for TASK."
  (format "roost:%s:%s:%s" (roost--host-label (roost--field task 'host))
          (roost--field task 'name) (substring (roost--field task 'id) 0 6)))

(defun roost--activate-workspace (task)
  "Restore TASK's saved window arrangement when perspective.el is active."
  (when (and roost-use-perspectives (bound-and-true-p persp-mode) (fboundp 'persp-switch))
    (persp-switch (roost--perspective-name task)))
  (setq roost--current-task (roost--key task)))

(defun roost--display-task (task)
  "Display TASK after its pane ownership has been checked on its host."
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
  (tmux-control--connect-or-switch (roost--field task 'host) (roost--field task 'socket) (roost--field task 'session))
  ;; Explicit window hop also works before the pane map arrives on connect.
  (let ((window (roost--field task 'windowId)) (pane (roost--field task 'paneId)))
    (unless (and (stringp window) (string-match-p "\\`@[0-9]+\\'" window)
                 (stringp pane) (string-match-p "\\`%[0-9]+\\'" pane)) (user-error "Invalid tmux target"))
    (tmux-control--send-command (format "select-window -t %s" window)) (tmux-control-select-pane pane)))

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
                      (roost--display-task current))))))

;;;###autoload
(defun roost-switch-task ()
  "Choose a task across hosts and restore its workspace."
  (interactive) (roost-open-task (roost--read-task "Switch task: ")))

;;;###autoload
(defun roost-new-task (directory name &optional base prompt)
  "Create a Claude task NAME in DIRECTORY from BASE, with optional PROMPT.
DIRECTORY may be a TRAMP path."
  (interactive (list (read-directory-name "Repository (local or TRAMP): " default-directory nil t)
                     (read-string "Task name: ") (read-string "Start from ref: " nil nil "HEAD") (read-string "Initial prompt (optional): ")))
  (let ((host (roost--directory-host directory))
        (setup (with-temp-buffer (setq default-directory directory) (hack-dir-local-variables-non-file-buffer) roost-setup-command)))
    (roost--request host "create"
                   (list (cons 'directory (file-local-name directory)) (cons 'name name) (cons 'base (or base "HEAD"))
                         (cons 'prompt (unless (string-empty-p (or prompt "")) prompt)) (cons 'command (vconcat roost-claude-command)) (cons 'setup setup)
                         (cons 'socket (or roost-socket-name (bound-and-true-p tmux-control-default-socket-name) "main"))
                         (cons 'session roost-session-name))
                   (lambda (task)
                     (cl-incf (gethash host roost--revisions 0)) (roost--remember-host host)
                     (setq task (roost--cache-task host task))
                     (roost-watch-mode 1) (roost--redraw) (roost-open-task task)
                     (message "Roost created %s on %s" name (roost--host-label host))))
    (message "Roost: creating %s…" name)))

(defun roost--act (task action &optional parameters callback)
  "Run ACTION on TASK with PARAMETERS, then CALLBACK."
  (let ((host (roost--field task 'host)))
    (roost--request host action (cons (cons 'id (roost--field task 'id)) parameters)
                   (lambda (updated)
                     (cl-incf (gethash host roost--revisions 0))
                     (setq updated (roost--cache-task host updated)) (roost--redraw)
                     (when callback (funcall callback updated)) (message "Roost %s: %s" (roost--field task 'name) action)))))

;;;###autoload
(defun roost-resume (&optional task)
  "Restart TASK, resuming its recorded Claude conversation."
  (interactive) (roost--act (roost--choose task) "resume" nil #'roost-open-task))

;;;###autoload
(defun roost-send (&optional task text)
  "Send TEXT as a literal pasted prompt to TASK's Claude pane."
  (interactive) (setq task (roost--choose task) text (or text (read-string (format "Send to %s: " (roost--field task 'name)))))
  (roost--act task "send" (list (cons 'text text))))

;;;###autoload
(defun roost-send-region (start end)
  "Send region START to END with file and line context to a chosen task."
  (interactive "r")
  (roost-send (roost--read-task "Send region to task: ")
              (format "%s:%d-%d\n\n%s" (if buffer-file-name (file-local-name buffer-file-name) (buffer-name))
                      (line-number-at-pos start) (line-number-at-pos end) (buffer-substring-no-properties start end))))

;;;###autoload
(defun roost-review (&optional task)
  "Open Magit on TASK's worktree, through TRAMP for remote tasks."
  (interactive) (setq task (roost--choose task)) (roost--activate-workspace task)
  (if (require 'magit nil t) (magit-status (roost--remote-directory task)) (dired (roost--remote-directory task))))

;;;###autoload
(defun roost-diff (&optional task)
  "Review TASK's tracked changes against its recorded starting commit."
  (interactive) (setq task (roost--choose task)) (require 'magit)
  (roost--activate-workspace task)
  (let ((default-directory (roost--remote-directory task))) (magit-diff-working-tree (roost--field task 'baseCommit))))

;;;###autoload
(defun roost-stop (&optional task)
  "Stop TASK's window, retaining its worktree, branch and conversation."
  (interactive) (setq task (roost--choose task))
  (when (yes-or-no-p (format "Stop %s's window and its processes? Work is kept. " (roost--field task 'name))) (roost--act task "stop")))

;;;###autoload
(defun roost-retire (&optional task)
  "Remove TASK's clean, merged worktree and branch, then stop its window."
  (interactive) (setq task (roost--choose task))
  (when (yes-or-no-p (format "Retire %s? Its clean, merged worktree and branch will be removed. " (roost--field task 'name)))
    (roost--act task "retire" nil #'roost--retired-workspace)))

;;;###autoload
(defun roost-merge-retire (&optional task)
  "Merge TASK's committed work into its recorded integration branch and retire.
Dirty worktrees are refused; review and commit in Magit first."
  (interactive) (setq task (roost--choose task))
  (when (yes-or-no-p (format "Merge committed work from %s and retire it? " (roost--field task 'name)))
    (roost--act task "merge" nil #'roost--retired-workspace)))

(defun roost--retired-workspace (task)
  "Remove TASK's perspective, retaining buffers."
  (when (and roost-use-perspectives (bound-and-true-p persp-mode) (fboundp 'persp-kill))
    (let ((persp-autokill-buffer-on-remove nil)) (persp-kill (roost--perspective-name task)))))

;;;###autoload
(defun roost-next-waiting ()
  "Cycle through live tasks whose Claude session needs attention."
  (interactive)
  (let* ((waiting (seq-filter (lambda (task) (and (not (gethash (roost--field task 'host) roost--errors))
                                                 (member (roost--field task 'status) '("ready" "permission")))) (roost-tasks)))
         (keys (mapcar #'roost--key waiting)) (tail (member roost--current-task keys)) (key (or (cadr tail) (car keys))))
    (unless key (user-error "No live tasks need attention")) (roost-open-task (gethash key roost--tasks))))

(defun roost--status-face (status)
  "Face for STATUS."
  (pcase status ((or "permission" "ready") 'warning) ((or "failed" "crashed" "offline") 'error)
         ((or "running" "background") 'font-lock-keyword-face) (_ 'shadow)))

(defun roost--elapsed (timestamp)
  "Format time since TIMESTAMP."
  (if (not timestamp) "?"
    (condition-case nil
        (let ((seconds (floor (max 0 (- (float-time) (float-time (date-to-time timestamp)))))))
          (cond ((< seconds 60) (format "%ds" seconds)) ((< seconds 3600) (format "%dm" (/ seconds 60)))
                (t (format "%dh%02dm" (/ seconds 3600) (/ (mod seconds 3600) 60))))) (error "?"))))

(defun roost--entries ()
  "Dashboard rows, entirely from cached state."
  (mapcar (lambda (task)
            (let* ((host (roost--field task 'host)) (status (if (gethash host roost--errors) "offline" (roost--field task 'status))))
              (list (roost--key task) (vector (roost--host-label host) (roost--field task 'name)
                                             (propertize status 'face (roost--status-face status)) (roost--elapsed (roost--field task 'updatedAt))
                                             (or (roost--field task 'diff) "") (roost--field task 'branch) (or (roost--field task 'task) ""))))) (roost-tasks)))
(defvar-keymap roost-dashboard-mode-map
  :doc "Task dashboard commands."
  "RET" #'roost-open-task "c" #'roost-new-task "d" #'roost-new-task "r" #'roost-review "D" #'roost-diff
  "e" #'roost-send "s" #'roost-resume "k" #'roost-stop "x" #'roost-retire "m" #'roost-merge-retire "n" #'roost-next-waiting "g" #'roost-refresh)
(defun roost--dashboard-display-settings ()
  "Keep table columns intact after global minor modes enable themselves."
  (when (derived-mode-p 'roost-dashboard-mode)
    (visual-line-mode -1)
    (display-line-numbers-mode -1)
    (setq truncate-lines t)))

(define-derived-mode roost-dashboard-mode tabulated-list-mode "Roost"
  "Tasks across hosts. All refreshes are asynchronous."
  (setq tabulated-list-format [("Host" 14 t) ("Task" 24 t) ("Status" 12 t) ("Since" 8 t)
                               ("Changes" 30 t) ("Branch" 36 t) ("Prompt" 0 nil)]
        tabulated-list-use-header-line nil
        truncate-lines t
        display-line-numbers nil
        tabulated-list-entries #'roost--entries)
  (add-hook 'after-change-major-mode-hook #'roost--dashboard-display-settings 90 t)
  (tabulated-list-init-header))

(defun roost--redraw ()
  "Refresh an existing dashboard without changing focus."
  (when-let* ((buffer (get-buffer "*roost*")))
    (with-current-buffer buffer
      (when (derived-mode-p 'roost-dashboard-mode)
        (setq header-line-format (concat " RET open · c new · r Magit · D diff · e send · s resume · k stop · x retire · g refresh"
                                         (when (> (hash-table-count roost--errors) 0) "  — host unavailable; last state retained")))
        (tabulated-list-print t)))))

;;;###autoload
(defun roost-status ()
  "Open the dashboard and watch configured and remembered hosts."
  (interactive)
  (let ((buffer (get-buffer-create "*roost*")))
    (with-current-buffer buffer (unless (derived-mode-p 'roost-dashboard-mode) (roost-dashboard-mode)))
    (pop-to-buffer buffer) (roost--redraw))
  (roost-watch-mode 1) (roost-refresh))

;;;###autoload
(define-minor-mode roost-watch-mode
  "Watch tasks asynchronously, retaining cached records during disconnects."
  :global t :lighter " Roost"
  (when roost--watch-timer (cancel-timer roost--watch-timer) (setq roost--watch-timer nil))
  (when roost-watch-mode (setq roost--watch-timer (run-with-timer roost-watch-interval roost-watch-interval (lambda () (roost-refresh t))))))
(defalias 'roost-list #'roost-switch-task)
(defalias 'roost-kill #'roost-stop)
(defalias 'roost-dispatch #'roost-new-task)
(provide 'roost)
;;; roost.el ends here
