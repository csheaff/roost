;;; roost-coder.el --- Optional Coder environments for Roost -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Clay Sheaff
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Prepared Coder templates provide persistent repositories and tools. Roost
;; keeps task UI and agent interaction; this module owns explicit environment
;; lifecycle and a durable local cache. No poll or SSH connection wakes a guest.

;;; Code:
(require 'roost)
(require 'coder)
(require 'diff-mode)

(defgroup roost-coder nil "Optional Coder environments." :group 'roost)
(defcustom roost-coder-connection nil
  "Coder connection plist: :url, :tokenFile and :command (an argv list).
Use a private token file, never a token in this setting.  The URL must
use HTTPS, or HTTP on loopback for an SSH tunnel.  The command is an
installed Coder CLI, such as (\"/path/to/coder\").  Roost writes only its
own private SSH and CLI configuration, never global settings."
  :type 'sexp :group 'roost-coder)
(defcustom roost-coder-templates nil
  "Prepared templates: (LABEL :id UUID :directory GUEST-REPOSITORY).
Each template must keep its repository, Roost state and agent data on
persistent storage, provide Git/Python/tmux and the chosen agent, and
permit an explicit lifetime without an automatic stop deadline.
Roost asks for the parameters the template's active version publishes."
  :type 'sexp :group 'roost-coder)
(defcustom roost-coder-state-directory (locate-user-emacs-file "roost/coder")
  "Private local controller state, outside every Coder workspace."
  :type 'directory :group 'roost-coder)
(defvar roost-coder--records (make-hash-table :test 'equal))
(defvar roost-coder--loaded nil)
(defvar roost-coder--polling (make-hash-table :test 'equal))
(defvar roost-coder--busy (make-hash-table :test 'equal))
(defvar roost-coder--polled (make-hash-table :test 'equal)
  "When a background refresh last asked Coder about each host, by `float-time'.")
(defvar tramp-rpc-ssh-args)
(defvar tramp-methods)
(defvar tramp-connection-properties)
(defvar tmux-control-ssh-options)
(defvar tmux-control-remote-tmux-socket-setup)
(defvar-local roost-coder--return nil)

(defun roost-coder--load ()
  "Read controller identities without contacting Coder or its guests."
  (unless roost-coder--loaded
    (setq roost-coder--loaded t)
    (when (featurep 'tramp) (roost-coder--tramp-setup))
    (when (file-directory-p (expand-file-name "coder" roost-coder-state-directory))
      (dolist (file (directory-files (expand-file-name "coder" roost-coder-state-directory)
                                     t "\\`[a-f0-9]\\{32\\}\\.json\\'"))
        (condition-case err
            (with-temp-buffer
              (insert-file-contents file)
              (roost-coder--accept
               (json-parse-buffer :object-type 'alist :array-type 'list
                                  :null-object nil :false-object nil)))
          (error (message "Roost could not read Coder identity %s: %s" file (error-message-string err))))))))

(defun roost-coder--record (host)
  "The durable record for HOST, without network I/O."
  (roost-coder--load)
  (gethash host roost-coder--records))

(defun roost-coder--hosts (hosts)
  "Add remembered environments to HOSTS without connecting."
  (roost-coder--load)
  (delete-dups (append hosts (hash-table-keys roost-coder--records))))

(defun roost-coder--accept (record &optional preserve)
  "Cache RECORD and its last tasks without claiming fresh guest observations."
  (let* ((host (alist-get 'host record))
         (state (alist-get 'state record))
         (tasks (or (and preserve (equal state "running")
                         (seq-filter (lambda (task) (equal (alist-get 'host task) host)) (roost-tasks)))
                    (alist-get 'tasks record)
                    `(((id . ,(concat "environment-" (alist-get 'id record)))
                       (name . ,(or (alist-get 'taskName record) (alist-get 'workspaceName record)))
                       (environmentOnly . t) (updatedAt . ,(alist-get 'createdAt record))
                       (status . "stopped") (agent . ,(or (alist-get 'taskAgent record) "claude")))))))
    ;; Pending requests and seed history remain private controller data.
    (setq record (seq-remove (lambda (entry) (memq (car entry) '(pending seed))) record))
    (puthash host record roost-coder--records)
    (maphash (lambda (key _) (when (equal (car key) host) (remhash key roost--tasks))) roost--tasks)
    (dolist (task tasks)
      (setq task (copy-tree task))
      (setf (alist-get 'host task) host)
      (setq task (roost-coder--decorate task))
      (unless (equal state "running")
        (setf (alist-get 'live task) nil (alist-get 'status task) "stopped"))
      ;; Cached observations do not trigger agent notifications.
      (puthash (roost--key task) task roost--tasks))
    record))

(defvar roost-coder--client nil
  "The Coder client of `roost-coder-connection', as (CONNECTION . CLIENT).")

(defun roost-coder--client ()
  "The `coder' client of `roost-coder-connection', kept beside Roost's records."
  (unless roost-coder-connection (user-error "Set roost-coder-connection first"))
  (unless (equal (car roost-coder--client) (cons roost-coder-state-directory roost-coder-connection))
    (setq roost-coder--client
          (cons (cons roost-coder-state-directory roost-coder-connection)
                (coder-connect (plist-get roost-coder-connection :url)
                               (plist-get roost-coder-connection :tokenFile)
                               (plist-get roost-coder-connection :command)
                               (expand-file-name "client" roost-coder-state-directory)))))
  (cdr roost-coder--client))

(defun roost-coder--call (action parameters success &optional failure)
  "Ask Roost's Coder controller ACTION with PARAMETERS, and don't wait.
The controller runs on this machine, with its records in
`roost-coder-state-directory', and asks Coder through `coder''s client."
  (let ((roost-state-directory roost-coder-state-directory)
        (client (roost-coder--client)))
    (roost--request nil action
                    `((client . ((transport . ,(coder-client-transport client))
                                 (configuration . ,(coder-client-configuration client))))
                      ,@parameters)
                    success (or failure (lambda (err) (message "Roost Coder: %s" err))) 1200)))

(defun roost-coder--parameters (parameters)
  "Read supported PARAMETERS from a prepared template."
  (vconcat
   (mapcar
    (lambda (parameter)
      (when (alist-get 'sensitive parameter)
        (user-error "Template asks for a secret parameter; configure secrets in Coder before using it in Roost"))
      (let* ((name (alist-get 'name parameter))
             (default (alist-get 'default_value parameter))
             (options (alist-get 'options parameter))
             (choices (mapcar (lambda (option)
                                (cons (or (alist-get 'name option) (alist-get 'value option))
                                      (alist-get 'value option))) options))
             (value (if choices
                        (cdr (assoc (completing-read (concat name ": ") choices nil t nil nil
                                                     (car (rassoc default choices))) choices))
                      (read-string (format "%s (%s): " name (alist-get 'type parameter)) default))))
        `((name . ,name) (value . ,value)))) parameters)))

;;;###autoload
(defun roost-coder-new-task ()
  "Create a task on hardware selected through a prepared Coder template.
Only committed source history is copied.  The canonical checkout,
selected base and resulting environment are separate, durable identities."
  (interactive)
  (unless roost-coder-templates (user-error "Set roost-coder-templates first"))
  (let* ((client (roost-coder--client))
         (template (assoc (completing-read "Coder template: " roost-coder-templates nil t)
                          roost-coder-templates))
         (id (plist-get (cdr template) :id))
         (guest (plist-get (cdr template) :directory))
         (details (coder-request-wait client "template" `((template . ,id))))
         (parameters (roost-coder--parameters (alist-get 'parameters details)))
         (directory (file-name-as-directory (read-directory-name "Checkout to start from: " nil nil t)))
         (base (read-string "Commit to start from: " "HEAD"))
         (name (read-string "Task name: "))
         (agent (completing-read "Agent: " roost--agents nil t nil nil roost-default-agent))
         (source-host (roost--directory-host directory))
         (guest-root roost-state-directory)
         (socket (or roost-socket-name (bound-and-true-p tmux-control-default-socket-name) "main"))
         (command (vconcat (roost--agent-command agent))))
    (unless (and (stringp guest) (file-name-absolute-p guest))
      (user-error "Configure an absolute persistent guest repository path"))
    (when (string-empty-p (string-trim name)) (user-error "Give the task a name"))
    (roost--request
     source-host "export-bundle" `((directory . ,(file-local-name directory)) (revision . ,base))
     (lambda (seed)
       (let* ((identity (md5 (format "%S" (list (random) (current-time) (emacs-pid) name))))
              (host (concat "roost-coder-" identity)))
         ;; Its row, while Coder makes it, which takes minutes.
         (puthash host t roost-coder--busy)
         (roost-coder--accept `((id . ,identity) (host . ,host) (state . "pending") (taskName . ,name)
                                (taskAgent . ,agent) (templateName . ,(car template))
                                (parameters . ,(append parameters nil)) (createdAt . ,(format-time-string "%FT%TZ" nil t))
                                (canonical . ((directory . ,(alist-get 'directory seed))))))
         (roost--redraw)
         (message "Starting %s in a Coder workspace…" name)
         (roost-coder--call
          "coder-create"
          `((id . ,identity) (template . ,id) (templateName . ,(car template)) (version . ,(alist-get 'version details))
            (parameters . ,parameters) (guestRoot . ,guest-root) (seed . ,seed)
            (canonical . ((host . ,(or source-host :null)) (directory . ,(alist-get 'directory seed))
                          (base . ,(alist-get 'tip seed))))
            (task . ((directory . ,guest) (name . ,name) (base . ,(alist-get 'tip seed))
                     (agent . ,agent) (command . ,command) (socket . ,socket)
                     (branchPrefix . ,roost-branch-prefix))))
          (lambda (record)
            (remhash host roost-coder--busy)
            (roost-coder--accept record)
            (roost-watch-mode 1)
            (roost--redraw)
            ;; It can finish after you have moved elsewhere: its terminal
            ;; doesn't take the place of what you are in.
            (message "Started %s in a Coder workspace: RET in Roost opens it" name))
          (lambda (err)
            (remhash host roost-coder--busy)
            (roost-coder--recover)
            (message "Couldn't start %s in a Coder workspace: %s; E tries again" name err))))))))

(defun roost-coder--recover ()
  "Reload durable identities after an interrupted provision."
  (roost-coder--call "coder-cached" nil
                     (lambda (records) (mapc #'roost-coder--accept records) (roost--redraw))))

(defconst roost-coder--poll-interval 30
  "Seconds between a background refresh's asks of Coder about a workspace.")

(defun roost-coder--refresh (refresh host quiet &optional ids)
  "Ask Coder whether HOST's workspace runs, then call REFRESH with HOST,
QUIET and IDS if it does.  A background refresh, QUIET, asks Coder at
most every `roost-coder--poll-interval' seconds, and in between
refreshes a running workspace's tasks as for any host."
  (if-let* ((record (roost-coder--record host)))
      (cond ((or (gethash host roost-coder--polling) (gethash host roost-coder--busy)))
            ((and quiet (< (- (float-time) (gethash host roost-coder--polled 0)) roost-coder--poll-interval))
             (when (equal (alist-get 'state record) "running")
               (funcall refresh host quiet ids)))
            (t
             (puthash host t roost-coder--polling)
             (puthash host (float-time) roost-coder--polled)
             (let ((revision (gethash host roost--revisions 0)))
               (roost-coder--call
                "coder-status" `((environment . ,(alist-get 'id record)))
                (lambda (updated)
                  (remhash host roost-coder--polling)
                  ;; Not if you started or stopped it meanwhile.
                  (when (and (= revision (gethash host roost--revisions 0))
                             (not (gethash host roost-coder--busy)))
                    (roost-coder--accept updated t)
                    (remhash host roost--errors)
                    (if (equal (alist-get 'state updated) "running")
                        (funcall refresh host quiet ids)
                      (roost--redraw))))
                (lambda (err)
                  (remhash host roost-coder--polling)
                  (when (= revision (gethash host roost--revisions 0))
                    (setf (alist-get 'state record) "unavailable" (alist-get 'error record) err)
                    (roost-coder--accept record)
                    (roost--redraw)))))))
    (funcall refresh host quiet ids)))

(defun roost-coder--snapshot (host tasks &rest _)
  "Keep TASKS, as HOST's workspace has them, for while it sleeps.
Only when they changed: each refresh would otherwise write them."
  (when-let* ((record (roost-coder--record host))
              ((not (equal tasks (alist-get 'tasks record)))))
    (let ((updated (copy-tree record)))
      (setf (alist-get 'tasks updated) tasks)
      (roost-coder--accept updated))
    (roost-coder--call "coder-snapshot" `((environment . ,(alist-get 'id record))
                                          (tasks . ,(json-parse-string
                                                     (json-encode (vconcat tasks))
                                                     :object-type 'alist :array-type 'array
                                                     :null-object :null :false-object :false)))
                       #'ignore #'ignore)))

(defun roost-coder--decorate (task)
  "Keep environment identity on TASK after individual agent actions."
  (when-let* ((record (roost-coder--record (alist-get 'host task))))
    (setf (alist-get 'coderEnvironment task) (alist-get 'id record)
          (alist-get 'environmentState task) (alist-get 'state record)
          (alist-get 'environmentError task) (alist-get 'error record)
          (alist-get 'environmentTemplate task) (alist-get 'templateName record)
          (alist-get 'environmentProfile task)
          (when (alist-get 'parameters record)
            (mapconcat (lambda (parameter) (format "%s=%s" (alist-get 'name parameter) (alist-get 'value parameter)))
                       (alist-get 'parameters record) ", "))
          (alist-get 'environmentReturn task)
          (when-let* ((canonical (alist-get 'canonical record))
                      (directory (alist-get 'directory canonical)))
            (if (alist-get 'host canonical)
                (format "%s on %s" directory (roost--host-label (alist-get 'host canonical)))
              (abbreviate-file-name directory))))
    (when (gethash (roost--key task) roost--tasks)
      (puthash (roost--key task) task roost--tasks)))
  task)

(defun roost-coder--request (request host action parameters success &optional failure timeout)
  "Make REQUEST of HOST, unless HOST is a workspace that isn't running.
Its tasks are where the workspace was made to keep them, whatever
`roost-state-directory' says now."
  (if-let* ((record (roost-coder--record host)))
      (if (equal (alist-get 'state record) "running")
          (let ((roost-state-directory (or (alist-get 'guestRoot record) roost-state-directory)))
            (funcall request host action parameters success failure timeout))
        (funcall (or failure (lambda (err) (user-error "%s" err)))
                 "Its Coder workspace is asleep: E starts it"))
    (funcall request host action parameters success failure timeout)))

(defun roost-coder--ssh-options (host)
  "Isolated SSH arguments for a Coder HOST, else nil."
  (when (roost-coder--record host)
    (list "-F" (expand-file-name "coder/ssh_config" roost-coder-state-directory))))

(defun roost-coder--python-command (command host code)
  "Run COMMAND for HOST with only that host's isolated SSH file."
  (when host (require 'tmux-control nil t))
  (let ((tmux-control-ssh-options (append (roost-coder--ssh-options host)
                                          (bound-and-true-p tmux-control-ssh-options)))
        (tmux-control-remote-tmux-socket-setup
         (if (roost-coder--record host) "export TMUX_TMPDIR=/tmp"
           (bound-and-true-p tmux-control-remote-tmux-socket-setup)))
        (roost-state-directory (if (roost-coder--record host) roost-coder-state-directory roost-state-directory)))
    (funcall command host code)))

(defun roost-coder--tmux-ssh (command host remote-command)
  "Give tmux COMMAND HOST's isolated SSH options, including on reconnect."
  (let ((tmux-control-ssh-options (append (roost-coder--ssh-options host) tmux-control-ssh-options)))
    (when (and (roost-coder--record host)
               (stringp tmux-control-remote-tmux-socket-setup)
               (string-prefix-p tmux-control-remote-tmux-socket-setup remote-command))
      (setq remote-command (concat "export TMUX_TMPDIR=/tmp"
                                   (substring remote-command (length tmux-control-remote-tmux-socket-setup)))))
    (funcall command host remote-command)))

(defconst roost-coder--host-regexp "roost-coder-[0-9a-f]\\{32\\}"
  "Matches the host name of a Coder workspace of Roost's.")

(defun roost-coder--tramp-setup ()
  "Have TRAMP's ssh and scp methods use Roost's SSH file for its workspaces.
Through `tramp-connection-properties', for file names on those hosts
only: other hosts, and `tramp-methods', stay as they are."
  (let ((options (list "-F" (expand-file-name "coder/ssh_config" roost-coder-state-directory))))
    (dolist (method '("ssh" "sshx" "scp" "scpx"))
      (let ((regexp (format "\\`/%s:\\(?:[^@:/]+@\\)?%s:" method roost-coder--host-regexp)))
        (dolist (parameter '(tramp-login-args tramp-copy-args))
          (when-let* ((arguments (cadr (assq parameter (cdr (assoc method tramp-methods)))))
                      (property (string-remove-prefix "tramp-" (symbol-name parameter))))
            (setq tramp-connection-properties
                  (cons (list regexp property (cons options (remove options arguments)))
                        (seq-remove (lambda (entry) (and (equal (car entry) regexp) (equal (cadr entry) property)))
                                    tramp-connection-properties)))))))))

(defun roost-coder--rpc-handler (handler operation &rest args)
  "Call tramp-rpc's HANDLER for OPERATION on ARGS, through Roost's SSH file
when the file is in a Coder workspace of Roost's.  tramp-rpc starts ssh
itself, with `tramp-rpc-ssh-args'."
  (if-let* ((host (seq-some (lambda (file)
                              (and (stringp file)
                                   (string-match "\\`/[^/:|]+:\\(?:[^@:/|]+@\\)?\\([^:/|]+\\):" file)
                                   (match-string 1 file)))
                            (append args (list default-directory))))
            ((string-match-p (concat "\\`" roost-coder--host-regexp "\\'") host)))
      (let ((tramp-rpc-ssh-args (append (roost-coder--ssh-options host) (bound-and-true-p tramp-rpc-ssh-args))))
        (apply handler operation args))
    (apply handler operation args)))

(defun roost-coder--host-label (label host)
  "LABEL for HOST, or a short one for a Coder workspace of Roost's, whose
host name is long and random."
  (if (and (stringp host) (string-prefix-p "roost-coder-" host) (roost-coder--record host))
      (concat "Coder " (substring host 12 18))
    (funcall label host)))

(defun roost-coder--environment (task)
  "TASK's environment record, or a `user-error' when it has none."
  (or (roost-coder--record (roost--field task 'host))
      (user-error "%s isn't in a Coder workspace" (roost--field task 'name))))

(defun roost-coder--change (action task)
  "Ask the controller to start or stop TASK's environment, as ACTION says.
Its agents are left alone: stopping refuses while one runs, and
starting resumes none."
  (let* ((start (equal action "coder-start"))
         (record (roost-coder--environment task))
         (host (roost--field task 'host))
         (name (roost--field task 'name)))
    (cond ((gethash host roost-coder--busy)
           (user-error "%s's environment is already %s" name (alist-get 'state (roost-coder--record host))))
          ((and start (not (roost-coder--start-applies-p task)))
           (user-error "%s's environment is %s" name (roost--field task 'environmentState)))
          ((and (not start) (not (member (roost--field task 'environmentState) '("running" "preparing"))))
           (user-error "%s's environment isn't running" name))
          ((and (not start) (not (roost-coder--stop-applies-p task)))
           (user-error "An agent runs in %s's environment: stop each with K first" name)))
    (when (or start (y-or-n-p (format "Stop %s's environment?  Everything running in it stops; its disk is kept. "
                                      name)))
      (puthash host t roost-coder--busy)
      (cl-incf (gethash host roost--revisions 0))
      (let ((pending (copy-tree record)))
        (setf (alist-get 'state pending) (if start "starting" "stopping"))
        (roost-coder--accept pending)
        (roost--redraw))
      (message "%s %s's environment…" (if start "Starting" "Stopping") name)
      (roost-coder--call
       action `((environment . ,(alist-get 'id record)))
       (lambda (updated)
         (remhash host roost-coder--busy)
         (roost-coder--accept updated)
         (roost--redraw)
         (message "%s %s's environment" (if start "Started" "Stopped") name))
       (lambda (err)
         (remhash host roost-coder--busy)
         (roost-coder--recover)
         (message "Couldn't %s %s's environment: %s" (if start "start" "stop") name err))))))

(defun roost-coder-start (&optional task)
  "Start the Coder workspace TASK runs in, or finish setting it up.
Its agent stays stopped: \[roost-resume] resumes it."
  (interactive)
  (roost-coder--change "coder-start" (roost--choose task)))

(defun roost-coder-stop (&optional task)
  "Stop the Coder workspace TASK runs in, keeping its disk.
Every agent in it must be stopped first, with \[roost-stop]."
  (interactive)
  (roost-coder--change "coder-stop" (roost--choose task)))

(defun roost-coder-return (&optional task)
  "Fetch TASK's commits to your checkout, to a ref of their own, and show them.
The ref is refs/roost/returns/COMMIT, in the checkout the task started
from.  Its branch, index and files stay as they are: merge the ref there
yourself, in Magit or Git.  Its agent must not be at work, and its
changes must be committed."
  (interactive)
  (setq task (roost--choose task))
  (let* ((record (roost-coder--environment task))
         (canonical (alist-get 'canonical record))
         (generation roost--open-generation)
         (origin (window-buffer (selected-window))))
    (unless (roost-coder--return-applies-p task)
      (user-error "%s" (cond ((roost--field task 'environmentOnly) "Its environment has no task yet")
                             ((roost--environment-down-p task) "Start its environment first: E")
                             ((roost--field task 'dirty) "Commit its changes first: r opens Magit")
                             ((eql (roost--field task 'ahead) 0) "It has no commits to fetch")
                             (t "Its agent is at work: wait for it to finish"))))
    (message "Fetching %s's commits…" (roost--field task 'name))
    (roost-coder--call
     "coder-export" `((environment . ,(alist-get 'id record)) (taskId . ,(alist-get 'id task)))
     (lambda (bundle)
       (roost--request
        (alist-get 'host canonical) "import-bundle"
        `((directory . ,(alist-get 'directory canonical)) (bundle . ,bundle))
        (lambda (returned)
          (let ((buffer (get-buffer-create (format "*Roost return: %s*" (alist-get 'name task)))))
            (with-current-buffer buffer
              (roost-coder-return-mode)
              (setq roost-coder--return returned
                    default-directory (roost--host-directory (alist-get 'host canonical)
                                                             (alist-get 'directory canonical)))
              (roost-coder--render-return))
            (when (and (= generation roost--open-generation)
                       (eq origin (window-buffer (selected-window)))
                       (not (active-minibuffer-window)))
              (pop-to-buffer buffer))
            (message "Fetched %s's commits to %s" (roost--field task 'name) (alist-get 'ref returned))))
        (lambda (err) (message "Couldn't fetch %s's commits: %s" (roost--field task 'name) err))))
     (lambda (err) (message "Couldn't fetch %s's commits: %s" (roost--field task 'name) err)))))

(defvar-keymap roost-coder-return-mode-map
  :parent diff-mode-map
  "q" #'quit-window)

(define-derived-mode roost-coder-return-mode diff-mode "Roost Fetched"
  "A task's commits, fetched from its Coder workspace to a ref of your checkout's."
  (setq buffer-read-only t))

(defun roost-coder--render-return ()
  "Show the commits `roost-coder--return' says were fetched, and where to."
  (let ((inhibit-read-only t) (position (point))
        (ref (alist-get 'ref roost-coder--return)))
    (erase-buffer)
    (insert (propertize (format "Fetched to %s, in %s.\nReview, then merge it there, in Magit or with git merge %s.\n%s\n\n"
                                ref (abbreviate-file-name (or (alist-get 'directory roost-coder--return) ""))
                                ref (substitute-command-keys "\\<roost-coder-return-mode-map>\\[quit-window] puts this away."))
                        'face 'roost-dim)
            (or (alist-get 'diff roost-coder--return) ""))
    (goto-char (min position (point-max)))))

(defconst roost-coder--under-way '("starting" "stopping" "pending" "canceling" "deleting")
  "Environment states a build is changing, which nothing should interrupt.")

(defun roost-coder--start-applies-p (task)
  "Whether TASK's environment can be started, or its setup finished."
  (and (roost--field task 'coderEnvironment)
       (not (gethash (roost--field task 'host) roost-coder--busy))
       (not (member (roost--field task 'environmentState)
                    (append '("running" "missing" "deleted") roost-coder--under-way)))))

(defun roost-coder--stop-applies-p (task)
  "Whether TASK's environment runs, with no agent of Roost's at work in it."
  (and (roost--field task 'coderEnvironment)
       (not (gethash (roost--field task 'host) roost-coder--busy))
       (member (roost--field task 'environmentState) '("running" "preparing"))
       (not (seq-some (lambda (other)
                        (and (equal (roost--field other 'host) (roost--field task 'host))
                             (roost--agent-running-p other)))
                      (roost-tasks)))))

(defun roost-coder--return-applies-p (task)
  "Whether TASK has committed work to fetch, its agent not at work."
  (and (roost--field task 'coderEnvironment)
       (not (roost--field task 'environmentOnly))
       (equal (roost--field task 'environmentState) "running")
       (not (member (roost--field task 'status) '("starting" "running" "permission" "background")))
       (not (roost--field task 'dirty))
       (not (eql (roost--field task 'ahead) 0))))

(function-put 'roost-coder-start 'roost-applies #'roost-coder--start-applies-p)
(function-put 'roost-coder-stop 'roost-applies #'roost-coder--stop-applies-p)
(function-put 'roost-coder-return 'roost-applies #'roost-coder--return-applies-p)

(defun roost-coder--menu-p ()
  "Whether the task `roost-dispatch' acts on runs in a Coder workspace."
  (and (roost--field (roost--dispatch-task) 'coderEnvironment) t))

(defun roost-coder--start-inapt-p () "See `roost--dispatch-inapt-p'." (roost--dispatch-inapt-p 'roost-coder-start))
(defun roost-coder--stop-inapt-p () "See `roost--dispatch-inapt-p'." (roost--dispatch-inapt-p 'roost-coder-stop))
(defun roost-coder--return-inapt-p () "See `roost--dispatch-inapt-p'." (roost--dispatch-inapt-p 'roost-coder-return))

;; One menu, Roost's: each key in it means what it means in the
;; dashboard, sidebar and task panel, so a key pressed there with the
;; menu left open does what it says.
(unless (ignore-errors (transient-get-suffix 'roost-dispatch "C"))
  (transient-append-suffix 'roost-dispatch "c" '("C" "New Coder task" roost-coder-new-task))
  (transient-append-suffix 'roost-dispatch '(0 3)
    ;; Each says when it shows, rather than the group: unloaded, it goes
    ;; with them.
    ["Environment"
     ("E" "Start" roost-coder-start :if roost-coder--menu-p :inapt-if roost-coder--start-inapt-p)
     ("Z" "Stop" roost-coder-stop :if roost-coder--menu-p :inapt-if roost-coder--stop-inapt-p)
     ("F" "Fetch commits" roost-coder-return :if roost-coder--menu-p :inapt-if roost-coder--return-inapt-p)]))

(dolist (map (list roost-dashboard-mode-map roost-task-info-mode-map))
  (keymap-set map "C" #'roost-coder-new-task)
  (keymap-set map "E" #'roost-coder-start)
  (keymap-set map "Z" #'roost-coder-stop)
  (keymap-set map "F" #'roost-coder-return))

(advice-add 'roost--hosts :filter-return #'roost-coder--hosts)
(advice-add 'roost--host-label :around #'roost-coder--host-label)
(advice-add 'roost--refresh-host :around #'roost-coder--refresh)
(advice-add 'roost--apply-snapshot :after #'roost-coder--snapshot)
(advice-add 'roost--cache-task :filter-return #'roost-coder--decorate)
(advice-add 'roost--request :around #'roost-coder--request)
(advice-add 'roost--python-command :around #'roost-coder--python-command)
(with-eval-after-load 'tramp
  (roost-coder--tramp-setup))
(with-eval-after-load 'tramp-rpc
  (advice-add 'tramp-rpc-file-name-handler :around #'roost-coder--rpc-handler))
(with-eval-after-load 'tmux-control
  (advice-add 'tmux-control--ssh-args :around #'roost-coder--tmux-ssh))

(defun roost-coder-unload-function ()
  "Take Coder workspaces out of Roost: their tasks, keys, menu and advice."
  (maphash (lambda (key _) (when (gethash (car key) roost-coder--records) (remhash key roost--tasks)))
           roost--tasks)
  (dolist (key '("C" "E" "Z" "F"))
    (ignore-errors (transient-remove-suffix 'roost-dispatch key))
    (dolist (map (list roost-dashboard-mode-map roost-task-info-mode-map))
      (keymap-unset map key t)))
  (advice-remove 'roost--hosts #'roost-coder--hosts)
  (advice-remove 'roost--host-label #'roost-coder--host-label)
  (advice-remove 'roost--refresh-host #'roost-coder--refresh)
  (advice-remove 'roost--apply-snapshot #'roost-coder--snapshot)
  (advice-remove 'roost--cache-task #'roost-coder--decorate)
  (advice-remove 'roost--request #'roost-coder--request)
  (advice-remove 'roost--python-command #'roost-coder--python-command)
  (when (fboundp 'tramp-rpc-file-name-handler)
    (advice-remove 'tramp-rpc-file-name-handler #'roost-coder--rpc-handler))
  (when (fboundp 'tmux-control--ssh-args)
    (advice-remove 'tmux-control--ssh-args #'roost-coder--tmux-ssh))
  (when (boundp 'tramp-connection-properties)
    (setq tramp-connection-properties
          (seq-remove (lambda (entry) (string-search "roost-coder-" (or (car entry) "")))
                      tramp-connection-properties)))
  (when (fboundp 'roost--redraw) (roost--redraw))
  ;; Continue with the standard unloading.
  nil)

(provide 'roost-coder)
;;; roost-coder.el ends here
