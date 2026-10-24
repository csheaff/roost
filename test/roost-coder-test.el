;;; roost-coder-test.el --- Optional environment invariants -*- lexical-binding: t; -*-
(require 'roost-test)
(require 'roost-coder)
(defvar tmux-control-ssh-options nil)
(defvar tramp-rpc-ssh-args nil)
(defvar tmux-control-remote-tmux-socket-setup nil)

(defun roost-coder-test--record (&optional state)
  (copy-tree `((id . ,(make-string 32 ?a)) (host . "roost-coder-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    (workspaceName . "synthetic") (state . ,(or state "stopped"))
    (tasks . (((id . "bbbbbbbbbbbbbbbb") (name . "Coder task") (status . "ready")
               (agent . "claude") (repo . "/repo") (worktree . "/worktree")
               (branch . "roost/task") (integrationBranch . "main") (live . t)))))))

(ert-deftest roost-coder-sleeping-tasks-are-visible-and-cannot-use-guest-actions ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record)))
           (host (alist-get 'host record))
           (task (gethash (list host "bbbbbbbbbbbbbbbb") roost--tasks)))
      (should (member host (roost--hosts)))
      (should (equal (roost--host-label host) "Coder aaaaaa"))
      (should (equal (roost--host-label "roost-coder-elsewhere") "roost-coder-elsewhere"))
      (should (equal (roost--display-status task) "asleep"))
      (should-not (alist-get 'live task))
      (dolist (command '(roost-open-task roost-resume roost-send roost-review roost-files roost-merge-retire
                         roost-coder-stop roost-coder-return))
        (should-not (roost--action-applies-p task command)))
      (dolist (command '(roost-task-info roost-coder-start))
        (should (roost--action-applies-p task command)))
      (should (string-match-p "E" (roost--next-step task)))
      (let (error)
        (roost--request host "inspect" nil #'ignore (lambda (err) (setq error err)))
        (should (string-match-p "asleep: E starts it" error))))))

(ert-deftest roost-coder-polling-sleeping-workspaces-never-contacts-the-guest ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record)))
           (host (alist-get 'host record)) calls)
      (cl-letf (((symbol-function 'roost-coder--call)
                 (lambda (action _parameters success &optional _failure)
                   (push action calls) (funcall success record)))
                ((symbol-function 'roost--redraw) #'ignore))
        (roost-coder--refresh (lambda (&rest _) (ert-fail "Connected to sleeping guest")) host t))
      (should (equal calls '("coder-status"))))))

(ert-deftest roost-coder-background-refreshes-ask-coder-every-so-often ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record "running")))
           (host (alist-get 'host record)) calls (refreshed 0))
      (cl-letf (((symbol-function 'roost-coder--call)
                 (lambda (action _parameters success &optional _failure)
                   (push action calls) (funcall success record)))
                ((symbol-function 'roost--redraw) #'ignore))
        (dotimes (_ 3)
          (roost-coder--refresh (lambda (&rest _) (cl-incf refreshed)) host t))
        (should (equal calls '("coder-status")))
        (should (eql refreshed 3))
        ;; Asleep, in between: nothing.
        (setf (alist-get 'state (roost-coder--record host)) "stopped")
        (roost-coder--refresh (lambda (&rest _) (ert-fail "Reached a sleeping workspace")) host t)
        (should (equal calls '("coder-status")))
        ;; g asks Coder each time.
        (roost-coder--refresh #'ignore host nil)
        (should (equal calls '("coder-status" "coder-status")))))))

(ert-deftest roost-coder-snapshots-only-what-changed ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record "running")))
           (host (alist-get 'host record)) calls)
      (cl-letf (((symbol-function 'roost-coder--call) (lambda (action &rest _) (push action calls))))
        (roost-coder--snapshot host (alist-get 'tasks (roost-coder--record host)))
        (should-not calls)
        (roost-coder--snapshot host (list (cons '(status . "running") (car (alist-get 'tasks record)))))
        (should (equal calls '("coder-snapshot")))))))

(ert-deftest roost-coder-a-new-task-has-its-row-while-coder-makes-it ()
  (roost-test--isolated
    (let ((roost-coder-connection '(:url "https://coder.example.org" :tokenFile "~/token" :command ("coder")))
          (roost-coder-templates '(("GPU" :id "11111111-2222-3333-4444-555555555555" :directory "/home/coder/repo")))
          created finish)
      (cl-letf (((symbol-function 'coder-request-wait)
                 (lambda (&rest _) '((version . "v1") (parameters . (((name . "size") (options . (((name . "Large") (value . "l"))))))))))
                ((symbol-function 'completing-read) (lambda (prompt &rest _) (if (string-prefix-p "size" prompt) "Large" (if (string-prefix-p "Agent" prompt) "claude" "GPU"))))
                ((symbol-function 'read-directory-name) (lambda (&rest _) "/src/notes/"))
                ((symbol-function 'read-string) (lambda (prompt &rest _) (if (string-prefix-p "Task" prompt) "Train it" "HEAD")))
                ((symbol-function 'roost--request)
                 (lambda (_host action _parameters success &rest _)
                   (should (equal action "export-bundle"))
                   (funcall success '((tip . "abc") (directory . "/src/notes")))))
                ((symbol-function 'roost-coder--call)
                 (lambda (action parameters success &optional failure)
                   (setq created (cons action parameters) finish (list success failure))))
                ((symbol-function 'roost-watch-mode) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore))
        (roost-coder-new-task)
        (should (equal (car created) "coder-create"))
        (let* ((host (concat "roost-coder-" (alist-get 'id (cdr created))))
               (row (car (roost-tasks))))
          (should (equal (roost--field row 'host) host))
          (should (equal (roost--field row 'name) "Train it"))
          (should (equal (roost--display-status row) "waking"))
          (should (equal (roost--field row 'environmentProfile) "size=l"))
          (should (gethash host roost-coder--busy))
          (should-error (roost-coder-start row) :type 'user-error)
          ;; It failed: its row stays, to start again.
          (cl-letf (((symbol-function 'roost-coder--recover) #'ignore))
            (funcall (nth 1 finish) "Coder said 400: no"))
          (should-not (gethash host roost-coder--busy)))))))

(ert-deftest roost-coder-stale-metadata-does-not-win-over-explicit-start ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record)))
           (host (alist-get 'host record)) reply)
      (cl-letf (((symbol-function 'roost-coder--call)
                 (lambda (_action _parameters success &optional _failure) (setq reply success))))
        (roost-coder--refresh (lambda (&rest _) (ert-fail "Stale callback contacted guest")) host t)
        (cl-incf (gethash host roost--revisions 0))
        (roost-coder--accept (roost-coder-test--record "running"))
        (funcall reply record))
      (should (equal (alist-get 'state (roost-coder--record host)) "running")))))

(ert-deftest roost-coder-ordinary-hosts-keep-their-transport-and-refresh ()
  (roost-test--isolated
    (let (refreshed)
      (roost-coder--refresh (lambda (&rest args) (setq refreshed args)) "ordinary" t '("id"))
      (should (equal refreshed '("ordinary" t ("id"))))
      (should-not (roost-coder--ssh-options "ordinary"))
      (should (equal (roost-coder--python-command (lambda (&rest _) tmux-control-ssh-options)
                                                  "ordinary" "code")
                      (bound-and-true-p tmux-control-ssh-options))))))

(ert-deftest roost-coder-isolated-ssh-applies-only-to-the-workspace ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record "running")))
           (host (alist-get 'host record))
           (tmux-control-ssh-options '("-o" "KeepAlive=yes")))
      (should (equal (car (roost-coder--python-command (lambda (&rest _) tmux-control-ssh-options) host "code")) "-F"))
      (should (equal tmux-control-ssh-options '("-o" "KeepAlive=yes"))))))

(ert-deftest roost-coder-tramp-reaches-only-its-workspaces-through-its-ssh-file ()
  (require 'tramp)
  (roost-test--isolated
    (let ((tramp-connection-properties nil)
          (tramp-cache-data (make-hash-table :test #'equal))
          (methods (copy-tree tramp-methods))
          (file (expand-file-name "coder/ssh_config" roost-coder-state-directory)))
      (roost-coder--tramp-setup)
      ;; Again, as on loading it again: no second entry, nor -F twice.
      (roost-coder--tramp-setup)
      (should (equal tramp-methods methods))
      (should (= (length tramp-connection-properties) 6))
      (dolist (method '("ssh" "scpx"))
        (let ((coder (tramp-dissect-file-name (format "/%s:roost-coder-%s:/repo" method (make-string 32 ?a))))
              (other (tramp-dissect-file-name (format "/%s:ordinary:/repo" method))))
          (should (equal (car (tramp-get-method-parameter coder 'tramp-login-args)) (list "-F" file)))
          (should (equal (tramp-get-method-parameter other 'tramp-login-args)
                         (cadr (assq 'tramp-login-args (cdr (assoc method tramp-methods)))))))))))

(ert-deftest roost-coder-rpc-reaches-only-its-workspaces-through-its-ssh-file ()
  (roost-test--isolated
    (roost-coder--accept (roost-coder-test--record "running"))
    (let ((tramp-rpc-ssh-args '("-v"))
          (handler (lambda (&rest _) tramp-rpc-ssh-args)))
      (should (equal (roost-coder--rpc-handler handler 'file-exists-p "/rpc:ordinary:/repo/file") '("-v")))
      (should (equal (roost-coder--rpc-handler handler 'file-exists-p
                                               (concat "/rpc:roost-coder-" (make-string 32 ?a) ":/repo/file"))
                     (append (roost-coder--ssh-options (concat "roost-coder-" (make-string 32 ?a))) '("-v"))))
      ;; Another host named, from a workspace's directory: that host's own.
      (let ((default-directory (concat "/rpc:roost-coder-" (make-string 32 ?a) ":/repo/")))
        (should (equal (roost-coder--rpc-handler handler 'file-exists-p "/rpc:ordinary:/repo/file") '("-v")))))))

(ert-deftest roost-coder-return-cannot-use-the-private-clone-merge-command ()
  (roost-test--isolated
    (roost-coder--accept (roost-coder-test--record "running"))
    (let ((task (car (roost-tasks))))
      (setf (alist-get 'ahead task) 2 (alist-get 'live task) nil (alist-get 'status task) "stopped")
      (should-not (roost--action-applies-p task 'roost-merge-retire))
      (should (roost--action-applies-p task 'roost-coder-return))
      (cl-letf (((symbol-function 'roost--act) (lambda (&rest _) (ert-fail "Private merge ran"))))
        (should (string-match-p "F fetches" (cadr (should-error (roost-merge-retire task) :type 'user-error)))))
      ;; What to do next names F, not m.
      (setf (alist-get 'status task) "ready" (alist-get 'live task) t)
      (should (string-match-p "\\`F fetches its commits" (substring-no-properties (roost--next-step task)))))))

(ert-deftest roost-coder-menu-keys-mean-what-they-mean-in-roost-s-views ()
  ;; With Roost's menu left open, a key pressed in a list or panel is the
  ;; menu's: it must do there what it does in the list.
  (let (keys)
    (dolist (key '("C" "E" "Z" "F"))
      (should (transient-get-suffix 'roost-dispatch key)))
    ;; Transient's layouts differ by version: a suffix is (CLASS . PLIST),
    ;; or (LEVEL CLASS PLIST).
    (cl-labels ((walk (layout)
                  (cond ((vectorp layout) (mapc #'walk layout))
                        ((not (proper-list-p layout)))
                        ((keywordp (car layout))
                         (when (plist-get layout :command)
                           (push (cons (plist-get layout :key) (plist-get layout :command)) keys)))
                        ((and (symbolp (car layout)) (keywordp (cadr layout))) (walk (cdr layout)))
                        (t (mapc #'walk layout)))))
      (walk (get 'roost-dispatch 'transient--layout)))
    (should (length> keys 25))
    (pcase-dolist (`(,key . ,command) keys)
      (dolist (map (list roost-dashboard-mode-map roost-sidebar-list-mode-map roost-task-info-mode-map))
        (let ((bound (keymap-lookup map key)))
          ;; The panel's g refreshes it, and its task, first.
          (unless (or (null bound) (and (eq bound 'roost-task-info-refresh) (eq command 'roost-refresh)))
            (should (equal (list key bound) (list key command)))))))
    ;; Each key once.
    (should (equal (length keys) (length (seq-uniq (mapcar #'car keys)))))))

(ert-deftest roost-coder-environment-commands-show-only-for-coder-tasks ()
  (roost-test--isolated
    (roost-coder--accept (roost-coder-test--record "running"))
    (let ((coder (car (roost-tasks)))
          (ordinary (roost-test--task "o1")))
      (cl-letf (((symbol-function 'roost--dispatch-task) (lambda () ordinary)))
        (should-not (roost-coder--menu-p)))
      (cl-letf (((symbol-function 'roost--dispatch-task) (lambda () coder)))
        (should (roost-coder--menu-p))
        ;; Running, with its agent at work: neither started again, nor stopped.
        (should (roost-coder--start-inapt-p))
        (should (roost-coder--stop-inapt-p)))
      (should (string-match-p "stop each with K"
                              (cadr (should-error (roost-coder-stop coder) :type 'user-error))))
      (setf (alist-get 'live coder) nil (alist-get 'status coder) "stopped")
      (puthash (roost--key coder) coder roost--tasks)
      (should (roost-coder--stop-applies-p coder))
      (should-error (roost-coder-start coder) :type 'user-error)
      (should-error (roost-coder-start ordinary) :type 'user-error))))

(ert-deftest roost-coder-controller-gets-coder-el-s-client ()
  (roost-test--isolated
    (let ((roost-coder-connection '(:url "https://coder.example.org" :tokenFile "~/token" :command ("coder")))
          sent)
      (cl-letf (((symbol-function 'roost--request)
                 (lambda (host action parameters &rest _) (setq sent (list host action parameters)))))
        (roost-coder--call "coder-cached" nil #'ignore))
      (should (equal (seq-take sent 2) '(nil "coder-cached")))
      (let ((client (alist-get 'client (nth 2 sent))))
        (should (string-suffix-p "scripts/coder_client.py" (alist-get 'transport client)))
        (should (file-equal-p (file-name-directory (alist-get 'configuration client))
                              (expand-file-name "client" roost-coder-state-directory))))
      (let ((roost-coder-connection nil))
        (should-error (roost-coder--call "coder-cached" nil #'ignore) :type 'user-error)))))

(ert-deftest roost-coder-parameter-choices-use-published-values-and-refuse-secrets ()
  (roost-test--isolated
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Small CPU")))
      (should (equal (roost-coder--parameters
                      '(((name . "profile") (options . (((name . "Small CPU") (value . "small")))))))
                     [((name . "profile") (value . "small"))])))
    (should-error (roost-coder--parameters '(((name . "secret") (sensitive . t)))) :type 'user-error)))

(ert-deftest roost-coder-failed-provision-keeps-a-task-shaped-identity ()
  (roost-test--isolated
    (let ((record (roost-coder-test--record "failed")))
      (setf (alist-get 'tasks record) nil (alist-get 'error record) "Template failed")
      (roost-coder--accept record)
      (let ((task (car (roost-tasks))))
        (should (string-prefix-p "environment-" (alist-get 'id task)))
        (should (equal (alist-get 'environmentError task) "Template failed"))
        (should (equal (roost--display-status task) "start failed"))))))

(ert-deftest roost-coder-snapshots-encode-decoded-agent-command-arrays ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record "running")))
           (host (alist-get 'host record))
           (tasks (copy-tree (alist-get 'tasks record))) encoded)
      (setf (alist-get 'command (car tasks)) '("python3" "fake.py"))
      (cl-letf (((symbol-function 'roost-coder--call)
                 (lambda (_action parameters _success &optional _failure)
                   (setq encoded (roost--json-encode parameters)))))
        (roost-coder--snapshot host tasks))
      (should (string-match-p "python3" encoded)))))

(ert-deftest roost-coder-helper-and-terminal-use-the-same-guest-socket-directory ()
  (roost-test--isolated
    (let* ((record (roost-coder--accept (roost-coder-test--record "running")))
           (host (alist-get 'host record))
           (tmux-control-remote-tmux-socket-setup "export TMUX_TMPDIR=$HOME/elsewhere")
           (tmux-control-ssh-options nil))
      (should (equal (roost-coder--python-command
                      (lambda (&rest _) tmux-control-remote-tmux-socket-setup) host "code")
                     "export TMUX_TMPDIR=/tmp"))
      (should (equal (cadr (roost-coder--tmux-ssh #'list host
                                                 "export TMUX_TMPDIR=$HOME/elsewhere && exec tmux"))
                     "export TMUX_TMPDIR=/tmp && exec tmux"))
      (should (equal tmux-control-remote-tmux-socket-setup "export TMUX_TMPDIR=$HOME/elsewhere")))))

(ert-deftest roost-coder-unloads-without-a-trace-in-roost ()
  ;; In an Emacs of its own: unloading here would leave the other tests
  ;; without it.
  (let ((emacs (expand-file-name invocation-name invocation-directory))
        (root (file-name-directory (locate-library "roost"))))
    (with-temp-buffer
      (should (zerop (call-process
                      emacs nil t nil "-Q" "--batch" "-L" root
                      "--eval"
                      (format "%S"
                              '(progn
                                 (require 'roost-coder)
                                 (require 'tramp)
                                 (unload-feature 'roost-coder)
                                 (dolist (key '("C" "E" "Z" "F"))
                                   (when (ignore-errors (transient-get-suffix 'roost-dispatch key))
                                     (error "%s is still in the menu" key))
                                   (when (keymap-lookup roost-dashboard-mode-map key)
                                     (error "%s is still bound" key)))
                                 (when (advice-member-p #'roost-coder--request 'roost--request)
                                   (error "Still advised"))
                                 (when (seq-some (lambda (entry) (string-search "roost-coder-" (or (car entry) "")))
                                                 tramp-connection-properties)
                                   (error "Still in TRAMP"))
                                 ;; Roost's menu still shows, with no Environment.
                                 (with-temp-buffer
                                   (let ((transient--original-buffer (current-buffer)))
                                     (transient-setup 'roost-dispatch)
                                     (transient-quit-all)))
                                 (princ "unloaded"))))))
        (should (string-search "unloaded" (buffer-string))))))

(provide 'roost-coder-test)
