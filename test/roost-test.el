;;; roost-test.el --- Task protocol and UI tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'roost)
(defvar persp-mode nil)
(defvar persp-modestring-short nil)
(defvar persp-modestring-dividers nil)

(defmacro roost-test--isolated (&rest body)
  `(let ((roost--tasks (make-hash-table :test 'equal))
         (roost-projects-file (expand-file-name "projects.json" (make-temp-file "roost-projects" t)))
         (roost--projects-loaded t) (roost--remembered-projects nil)
         (user-login-name "user")
         (roost--statuses (make-hash-table :test 'equal))
         (roost--errors (make-hash-table :test 'equal))
         (roost--installed (make-hash-table :test 'equal))
         (roost--refreshing (make-hash-table :test 'equal))
         (roost--revisions (make-hash-table :test 'equal))
         (roost--full-refresh-pending (make-hash-table :test 'equal))
         (roost--failures (make-hash-table :test 'equal))
         (roost--hosts-loaded t) (roost--remembered-hosts nil)
         (roost--requests nil) (roost-notify nil) (roost--current-task nil)) ,@body))

(defun roost-test--task (&optional id status)
  (copy-tree `((id . ,(or id "0123456789abcdef")) (name . "fix auth") (status . ,(or status "ready"))
    (worktree . "/home/user/work/fix auth") (branch . "codex/roost/fix-auth-123456")
    (socket . "main") (session . "roost-123456") (windowId . "@9") (paneId . "%12")
    (updatedAt . "2026-10-03T20:00:00+00:00") (task . "fix authentication"))))

(ert-deftest roost-qualified-task-identity ()
  (roost-test--isolated
   (roost--cache-task "host-a" (roost-test--task))
   (roost--cache-task "host-b" (roost-test--task))
   (should (= (length (roost-tasks)) 2))))

(ert-deftest roost-snapshot-is-host-local ()
  (roost-test--isolated
   (roost--cache-task "a" (roost-test--task))
   (roost--cache-task "b" (roost-test--task))
   (roost--apply-snapshot "a" nil)
   (should (= (length (roost-tasks)) 1))
   (should (equal (roost--field (car (roost-tasks)) 'host) "b"))))

(ert-deftest roost-quiet-refresh-retains-git-details ()
  (roost-test--isolated
   (roost--cache-task nil (append '((diff . "1 file changed") (dirty . t)) (roost-test--task)))
   (roost--apply-snapshot nil (list (roost-test--task)))
   (should (equal (roost--field (car (roost-tasks)) 'diff) "1 file changed"))))

(ert-deftest roost-notifies-once-and-not-on-initial-attachment ()
  (roost-test--isolated
   (let* ((roost-notify t) notices
         (roost-notify-function (lambda (title _body) (push title notices))))
     (roost--cache-task "dev" (roost-test--task nil "ready"))
     (should-not notices)
     (roost--cache-task "dev" (roost-test--task nil "running"))
     (roost--cache-task "dev" (roost-test--task nil "permission"))
     (roost--cache-task "dev" (roost-test--task nil "permission"))
     (should (= (length notices) 1)))))

(ert-deftest roost-notifies-on-fast-turns-that-finish-between-polls ()
  (roost-test--isolated
   (let* ((roost-notify t) notices
          (roost-notify-function (lambda (title _body) (push title notices)))
          (finished (append '((lastEvent . "Stop")) (roost-test--task))))
     (roost--cache-task "dev" (roost-test--task nil "ready"))
     (setf (alist-get 'updatedAt finished) "2026-10-03T20:00:01+00:00")
     (roost--cache-task "dev" finished)
     (roost--cache-task "dev" (copy-tree finished))
     (should (= (length notices) 1)))))

(ert-deftest roost-refresh-captures-each-host-and-rejects-stale-replies ()
  (roost-test--isolated
   (let ((roost-hosts '("a" "b")) callbacks)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (host _action _params success failure) (push (list host success failure) callbacks))))
       (roost-refresh t)
       (puthash "a" 1 roost--revisions)
       (dolist (callback callbacks) (funcall (nth 1 callback) (list (roost-test--task))))
       (should-not (gethash '("a" "0123456789abcdef") roost--tasks))
       (should (gethash '("b" "0123456789abcdef") roost--tasks))
       (should (= (hash-table-count roost--refreshing) 0))))))

(ert-deftest roost-offline-host-preserves-tasks-without-claiming-agent-crash ()
  (roost-test--isolated
   (let ((roost-hosts '("dev")))
     (roost--cache-task "dev" (roost-test--task))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params _success failure) (funcall failure "connection lost"))))
       (roost-refresh t))
     (should (equal (roost--field (car (roost-tasks)) 'status) "ready"))
     (should (equal (roost--display-status (car (roost-tasks))) "offline"))
     (with-temp-buffer
       (roost-dashboard-mode)
       (roost--render-dashboard)
       (should (string-match-p "unreachable; showing the last known state" (buffer-string)))
       (should (string-match-p "1 offline" (buffer-string)))))))

(ert-deftest roost-remote-path-respects-tramp-method-and-user ()
  (let ((tramp-methods (cons '("rpc" (tramp-login-program "ssh")) tramp-methods))
        (tramp-default-method "ssh")
        (tramp-default-method-alist '(("dev" nil "rpc"))))
    (should (equal (roost--remote-directory (append '((host . "dev")) (roost-test--task)))
                   "/rpc:dev:/home/user/work/fix auth/"))
    (should (equal (roost--remote-directory (append '((host . "alice@elsewhere")) (roost-test--task)))
                   "/ssh:alice@elsewhere:/home/user/work/fix auth/"))
    (should (equal (roost--directory-host "/rpc:alice@dev:/home/user/repo/") "alice@dev"))
    (should-not (roost--directory-host "/tmp/repo/"))
    (should-error (roost--directory-host "/ssh:dev#2222:/repo/") :type 'user-error)))

(ert-deftest roost-python-command-quotes-program-and-uses-stdin-for-data ()
  (cl-progv '(tmux-control-remote-tmux-socket-setup tmux-control-ssh-options)
      '("export TMUX_TMPDIR=/safe/socket" ("-o" "ProxyJump=jump"))
   (let* ((code "print('literal $() `ticks`')") (argv (roost--python-command "dev" code)))
    (should (equal (car argv) "ssh"))
    (should (member "ProxyJump=jump" argv))
    (should (equal (car (last argv)) (concat tmux-control-remote-tmux-socket-setup " && exec python3 -c " (shell-quote-argument code))))
    (should (equal (roost--python-command nil code) (list "python3" "-c" code))))))

(ert-deftest roost-open-checks-ownership-before-touching-the-ui ()
  (roost-test--isolated
   (let (requested displayed)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host action _params _success &optional _failure) (setq requested action)))
               ((symbol-function 'roost--display-task) (lambda (_) (setq displayed t))))
       (roost-open-task (roost-test--task))
       (should (equal requested "inspect")) (should-not displayed)))))

(ert-deftest roost-open-ignores-slower-earlier-navigation ()
  (roost-test--isolated
   (let (callbacks displayed)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params success &optional _failure) (push success callbacks)))
               ((symbol-function 'roost--display-task) (lambda (task) (setq displayed (roost--field task 'id)))))
       (roost-open-task (roost-test--task "1111111111111111"))
       (roost-open-task (roost-test--task "2222222222222222"))
       (funcall (car callbacks) (roost-test--task "2222222222222222"))
       (funcall (cadr callbacks) (roost-test--task "1111111111111111"))
       (should (equal displayed "2222222222222222"))))))

(ert-deftest roost-create-and-resume-callbacks-retain-remote-host ()
  (roost-test--isolated
   (let (opened)
     (cl-letf (((symbol-function 'hack-dir-local-variables-non-file-buffer) #'ignore)
               ((symbol-function 'roost--remember-host) #'ignore)
               ((symbol-function 'roost-watch-mode) #'ignore)
               ((symbol-function 'roost-open-task) (lambda (task) (setq opened task)))
               ((symbol-function 'roost--request)
                (lambda (_host _action _params success &optional _failure) (funcall success (roost-test--task)))))
       (roost-new-task "/ssh:dev:/repo/" "fix")
       (should (equal (roost--field opened 'host) "dev"))
       (setq opened nil)
       (roost-resume (gethash '("dev" "0123456789abcdef") roost--tasks))
       (should (equal (roost--field opened 'host) "dev"))))))

(ert-deftest roost-creation-selects-agent-command-and-preserves-claude-configuration ()
  (roost-test--isolated
   (let ((roost-claude-command '("claude" "--model" "sonnet"))
         (roost-agent-commands '(("codex" "codex" "--model" "test-model") ("pi" "pi" "--provider" "anthropic")))
         (roost-default-agent "pi") requests)
     (cl-letf (((symbol-function 'hack-dir-local-variables-non-file-buffer) #'ignore)
               ((symbol-function 'roost--request) (lambda (_host _action params &rest _) (push params requests))))
       (roost-new-task "/tmp/" "default")
       (should (equal (alist-get 'agent (car requests)) "pi"))
       (should (equal (alist-get 'command (car requests)) ["pi" "--provider" "anthropic"]))
       (roost-new-task "/tmp/" "codex" nil nil "codex")
       (should (equal (alist-get 'command (car requests)) ["codex" "--model" "test-model"]))
       (roost-new-task "/tmp/" "claude" nil nil "claude")
       (should (equal (alist-get 'command (car requests)) ["claude" "--model" "sonnet"]))
       (should-error (roost-new-task "/tmp/" "unknown" nil nil "unknown") :type 'user-error)
       (should (= (length requests) 3))))))

(ert-deftest roost-empty-dashboard-does-not-target-previous-task ()
  (roost-test--isolated
   (roost--cache-task nil (roost-test--task))
   (setq roost--current-task '(nil "0123456789abcdef"))
   (with-temp-buffer (roost-dashboard-mode) (should-not (roost--task-at-point)))))

(ert-deftest roost-context-follows-worktree-files-and-manual-perspective-switches ()
  (roost-test--isolated
   (let* ((a (roost--cache-task nil (roost-test--task "1111111111111111")))
          (b (roost-test--task "2222222222222222"))
          (persp-mode t))
     (setf (alist-get 'worktree b) "/home/user/work/second")
     (roost--cache-task nil b)
     (setq roost--current-task (roost--key a))
     (cl-letf (((symbol-function 'persp-current-name) (lambda () (roost--perspective-name b))))
       (with-temp-buffer
         (setq default-directory "/tmp/")
         (should (equal (roost--key (roost--task-at-point)) (roost--key b))))
       (with-temp-buffer
         (setq default-directory "/home/user/work/fix auth/src/" buffer-file-name "/home/user/work/fix auth/src/example.el")
         (should (equal (roost--key (roost--task-at-point)) (roost--key a)))))
     (cl-letf (((symbol-function 'persp-current-name) (lambda () "unrelated")))
       (with-temp-buffer (setq default-directory "/tmp/") (should-not (roost--task-at-point)))))))

(ert-deftest roost-context-distinguishes-hosts-and-directory-boundaries ()
  (roost-test--isolated
   (roost--cache-task "a" (roost-test--task))
   (roost--cache-task "b" (roost-test--task))
   (with-temp-buffer
     (setq default-directory "/ssh:b:/home/user/work/fix auth/src/")
     (should (equal (roost--field (roost--task-at-point) 'host) "b"))
     (setq default-directory "/ssh:b:/home/user/work/fix auth-other/")
     (should-not (roost--task-at-point)))))

(ert-deftest roost-perspective-bar-groups-many-tasks-and-preserves-ordinary-labels ()
  (roost-test--isolated
   (let* ((task (roost--cache-task "dev" (roost-test--task)))
          (current (roost--perspective-name task))
          (names (append (list "main" "notes" current)
                         (cl-loop for i from 1 to 99 collect (format "roost:dev:other-%d:%06x" i i))))
          (persp-mode t) (persp-modestring-short nil) (persp-modestring-dividers '("[" "]" "|"))
          (ordinary-map (make-sparse-keymap)))
     (cl-letf (((symbol-function 'persp-current-name) (lambda () current))
               ((symbol-function 'persp-names) (lambda () names))
               ((symbol-function 'persp-format-name) (lambda (name) (propertize name 'local-map ordinary-map))))
       (let* ((labels (roost--compact-perspective-mode-line '("original")))
              (text (apply #'concat labels)) (group (nth 5 labels)))
         (should (equal text "[main|notes|Roost: dev/fix auth +99]"))
         (should (eq (get-text-property 0 'local-map (nth 1 labels)) ordinary-map))
         (should (eq (lookup-key (get-text-property 0 'local-map group) [mode-line down-mouse-1]) 'ignore))
         (should (eq (lookup-key (get-text-property 0 'local-map group) [mode-line mouse-1]) 'roost-switch-task))
         (should-not (string-match-p "other-" text))
         (should (= (length names) 102)))
       (setq current "notes")
       (should (equal (apply #'concat (roost--compact-perspective-mode-line '("original"))) "[main|notes|Roost (100)]"))
       (setq persp-modestring-short t)
       (should (equal (roost--compact-perspective-mode-line '("notes")) '("notes")))
       (setq current (roost--perspective-name task))
       (should (equal (apply #'concat (roost--compact-perspective-mode-line '("original"))) "[Roost: dev/fix auth +99]"))))))

(ert-deftest roost-perspective-bar-bounds-long-labels-and-supports-restored-workspaces ()
  (roost-test--isolated
   (let* ((current (concat "roost:dev:" (make-string 100 ?a) ":123456"))
          (persp-mode t) (persp-modestring-short nil) (persp-modestring-dividers '("[" "]" "|")))
     (cl-letf (((symbol-function 'persp-current-name) (lambda () current))
               ((symbol-function 'persp-names) (lambda () (list current))))
       (let ((text (apply #'concat (roost--compact-perspective-mode-line '("original")))))
         (should (< (string-width text) 42))
         (should (string-match-p "Roost: dev:" text))
         (should-not (string-match-p "123456" text)))
       (let ((roost-compact-mode-line nil)) (should (equal (roost--compact-perspective-mode-line '("original")) '("original"))))
       (let ((roost-use-perspectives nil)) (should (equal (roost--compact-perspective-mode-line '("original")) '("original"))))
       (should-not (roost--compact-perspective-mode-line nil))))))

(ert-deftest roost-shell-pane-context-targets-its-task ()
  (roost-test--isolated
   (roost--cache-task "dev" (append '((shellPaneId . "%13")) (roost-test--task)))
   (with-temp-buffer
     (cl-progv '(tmux-control--host tmux-control--socket-name tmux-control--active-pane)
         '("dev" "main" "%13")
       (should (equal (roost--field (roost--task-at-point) 'host) "dev"))))))

(ert-deftest roost-new-task-defaults-to-primary-checkout-and-prefix-forks ()
  (roost-test--isolated
   (roost--cache-task "dev" (append '((repo . "/home/user/repo")) (roost-test--task)))
   (setq roost--current-task '("dev" "0123456789abcdef"))
   (let ((default-directory "/tmp/"))
     (save-window-excursion
       (unwind-protect
           (progn
             (roost--compose)
             (with-current-buffer roost--compose-buffer
               (should (string-suffix-p ":/home/user/repo/" (plist-get roost--compose-fields :directory)))
               (should-not (plist-get roost--compose-fields :base))
               (should (string-match-p "Start    primary checkout's current branch  C-c C-b" (buffer-string))))
             (roost--compose t)
             (with-current-buffer roost--compose-buffer
               (should (string-suffix-p ":/home/user/work/fix auth/" (plist-get roost--compose-fields :directory)))
               (should (equal (plist-get roost--compose-fields :base) "HEAD"))
               (should (string-match-p "HEAD of fix auth  C-c C-b · fork: includes its commits" (buffer-string)))))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-compose-derives-a-name-and-submits-the-draft ()
  (roost-test--isolated
   (let ((default-directory "/tmp/") created failure)
     (save-window-excursion
       (unwind-protect
           (cl-letf (((symbol-function 'roost--create-task)
                      (lambda (directory name base prompt agent on-success on-failure)
                        (setq created (list directory name base prompt agent) failure on-failure)
                        (ignore on-success))))
             (roost--compose)
             (with-current-buffer roost--compose-buffer
               (setq roost--compose-fields (plist-put roost--compose-fields :directory "/ssh:dev:/repo/"))
               (goto-char (point-max))
               (insert "Fix the CSV importer so quoted commas work.\nAdd tests.")
               (roost--compose-render)
               (should (string-match-p "Name     fix-csv-importer-quoted  C-c C-n · from the prompt" (buffer-string)))
               ;; Rewriting the fields keeps point in the prompt.
               (should (= (point) (point-max)))
               (should (string-match-p "Project  dev · /repo" (buffer-string)))
               ;; The fields above the line are not editable.
               (goto-char (point-min))
               (should-error (insert "x") :type 'text-read-only)
               (roost-compose-submit)
               (should (equal created '("/ssh:dev:/repo/" "fix-csv-importer-quoted" nil
                                        "Fix the CSV importer so quoted commas work.\nAdd tests." "claude")))
               (funcall failure "no such host")
               (should (string-match-p "Could not create the task: no such host" header-line-format))
               (should (buffer-live-p (current-buffer)))))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-compose-requires-a-project-and-a-prompt-or-name ()
  (roost-test--isolated
   (let ((default-directory "/tmp/"))
     (save-window-excursion
       (unwind-protect
           (progn
             (roost--compose)
             (with-current-buffer roost--compose-buffer
               (setq roost--compose-fields (plist-put roost--compose-fields :directory nil))
               (should-error (roost-compose-submit) :type 'user-error)
               (setq roost--compose-fields (plist-put roost--compose-fields :directory "/repo/"))
               (should-error (roost-compose-submit) :type 'user-error)))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-names-come-from-the-first-meaningful-words ()
  (should (equal (roost--name-from-prompt "Importing examples/october.csv crashes: the importer")
                 "importing-examples-october-csv"))
  (should (equal (roost--name-from-prompt "Please add a --json flag to the report") "add-json-flag-report"))
  (should (equal (roost--name-from-prompt "") "")))

(ert-deftest roost-shell-ignores-a-slower-earlier-navigation ()
  (roost-test--isolated
   (let (callback displayed)
     (cl-letf (((symbol-function 'roost--act) (lambda (_task _action _params cb) (setq callback cb)))
               ((symbol-function 'roost--display-task) (lambda (&rest _) (setq displayed t)))
               ((symbol-function 'roost--request) #'ignore))
       (roost-shell (roost-test--task))
       (roost-open-task (roost-test--task "2222222222222222"))
       (funcall callback (roost-test--task))
       (should-not displayed)))))

(ert-deftest roost-shell-shows-both-panes-without-toggling-existing-tiling-off ()
  (roost-test--isolated
   (let ((tiled nil) (tiles 0))
     (cl-letf (((symbol-function 'roost--act) (lambda (task _action _params cb) (funcall cb task)))
               ((symbol-function 'roost--display-task) #'ignore)
               ((symbol-function 'roost--focus-shell) #'ignore)
               ((symbol-function 'tmux-control--tiled-mode-p) (lambda () tiled))
               ((symbol-function 'tmux-control-tile) (lambda () (setq tiled t) (cl-incf tiles))))
       (roost-shell (roost-test--task)) (should (= tiles 1))
       (roost-shell (roost-test--task)) (should (= tiles 1))))))

(ert-deftest roost-shell-rpc-callback-uses-the-displayed-terminal-buffer ()
  (roost-test--isolated
   (save-window-excursion
     (let ((terminal (generate-new-buffer " *roost-test-terminal*")) seen)
       (unwind-protect
           (cl-letf (((symbol-function 'roost--act)
                      (lambda (task _action _params cb) (with-temp-buffer (funcall cb task))))
                     ((symbol-function 'roost--display-task)
                      (lambda (&rest _) (set-window-buffer (selected-window) terminal)))
                     ((symbol-function 'tmux-control--tiled-mode-p) (lambda () t))
                     ((symbol-function 'roost--focus-shell) (lambda (&rest _) (setq seen (current-buffer)))))
             (roost-shell (roost-test--task)) (should (eq seen terminal)))
         (kill-buffer terminal))))))

(ert-deftest roost-shell-deferred-focus-respects-later-file-and-workspace-navigation ()
  (roost-test--isolated
   (save-window-excursion
     (let* ((task (roost--cache-task "dev" (append '((shellPaneId . "%13")) (roost-test--task))))
            (agent (generate-new-buffer " *roost-test-agent*"))
            (shell (generate-new-buffer " *roost-test-shell*"))
            (file (generate-new-buffer " *roost-test-file*"))
            (origin (selected-window)) (target (split-window-right))
            (roost--open-generation 1) (persp-mode t)
            (perspective (roost--perspective-name task)) callback)
       (unwind-protect
           (progn
             (setq roost--current-task (roost--key task))
             (dolist (entry `((,agent . "%12") (,shell . "%13")))
               (with-current-buffer (car entry)
                 (setq-local tmux-control--host "dev" tmux-control--socket-name "main"
                             tmux-control--active-pane (cdr entry))))
             (set-window-buffer origin agent) (set-window-buffer target shell)
             (cl-letf (((symbol-function 'tmux-control--query) (lambda (_command cb) (funcall cb "@9")))
                       ((symbol-function 'run-at-time) (lambda (_delay _repeat cb &rest _) (setq callback cb)))
                       ((symbol-function 'persp-current-name) (lambda () perspective)))
               (roost--focus-shell task 1)
               (should (eq (selected-window) origin))
               (funcall callback) (should (eq (selected-window) target))
               (select-window origin) (set-window-buffer origin file)
               (funcall callback) (should (eq (selected-window) origin))
               (set-window-buffer origin agent) (setq perspective "another workspace")
               (funcall callback) (should (eq (selected-window) origin))
               (setq perspective (roost--perspective-name task) roost--open-generation 2)
               (funcall callback) (should (eq (selected-window) origin))))
         (mapc #'kill-buffer (list agent shell file)))))))

(ert-deftest roost-task-panel-keeps-identity-and-refreshes-without-focus-change ()
  (roost-test--isolated
   (let ((task (roost--cache-task nil (roost-test--task)))
         (buffer (get-buffer-create " *roost-test-info*")) (original (current-buffer)))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (roost-task-info-mode) (setq roost--buffer-task-key (roost--key task))
             (roost--render-task-info) (should (eq (roost--task-at-point) task)))
           (setf (alist-get 'status task) "stopped")
           (roost--redraw) (should (eq original (current-buffer)))
           (with-current-buffer buffer
             (should (string-match-p "stopped" (buffer-string))))
           (remhash (roost--key task) roost--tasks) (roost--redraw)
           (with-current-buffer buffer (should-error (roost--task-at-point) :type 'user-error)))
       (kill-buffer buffer)))))

(ert-deftest roost-next-attention-cycles-across-hosts-and-skips-offline ()
  (roost-test--isolated
   (roost--cache-task "a" (roost-test--task))
   (roost--cache-task "b" (roost-test--task nil "permission"))
   (roost--cache-task "c" (roost-test--task nil "running"))
   (let (opened)
     (cl-letf (((symbol-function 'roost-open-task)
                (lambda (task) (setq opened (roost--key task) roost--current-task opened))))
       ;; The permission request comes first, then the ready task, in turn.
       (roost-next-waiting) (should (equal (car opened) "b"))
       (roost-next-waiting) (should (equal (car opened) "a"))
       (roost-next-waiting) (should (equal (car opened) "b"))
       ;; A new permission request jumps ahead of the remaining ready tasks.
       (roost--cache-task "d" (roost-test--task nil "ready"))
       (roost-next-waiting) (should (equal (car opened) "a"))
       (roost--cache-task "c" (roost-test--task nil "permission"))
       (roost-next-waiting) (should (equal (car opened) "b"))
       (roost-next-waiting) (should (equal (car opened) "c"))
       (puthash "a" "offline" roost--errors)
       (puthash "b" "offline" roost--errors)
       (puthash "c" "offline" roost--errors)
       (roost-next-waiting) (should (equal (car opened) "d"))))))

(ert-deftest roost-background-refresh-never-steals-focus ()
  (roost-test--isolated
   (let ((buffer (get-buffer-create "*roost*")) (original (current-buffer)))
     (unwind-protect
         (progn (with-current-buffer buffer (roost-dashboard-mode))
                (roost--cache-task nil (roost-test--task))
                (roost--redraw) (should (eq (current-buffer) original)))
       (kill-buffer buffer)))))

(ert-deftest roost-async-rpc-installs-helper-and-returns-without-blocking ()
  (roost-test--isolated
   (let* ((root (make-temp-file "roost-rpc ' $ " t)) (roost-state-directory root)
          result failure finished)
     (unwind-protect
         (progn
           (roost--request nil "list" nil (lambda (value) (setq result value finished t))
                            (lambda (err) (setq failure err finished t)))
           (should-not finished)
           (let ((deadline (+ (float-time) 8)))
             (while (and (not finished) (< (float-time) deadline)) (accept-process-output nil .05)))
           (should finished) (should-not failure) (should-not result)
           (should (= (length (directory-files root nil "remote-.*\\.py")) 1))
           (should-not roost--requests))
       (delete-directory root t)))))

(ert-deftest roost-async-rpc-keeps-request-directory-after-dynamic-binding-ends ()
  (roost-test--isolated
   (let ((roots (list (make-temp-file "roost-root-a" t) (make-temp-file "roost-root-b" t)))
         (finished 0) failure)
     (unwind-protect
         (progn
           (dolist (root roots)
             (let ((roost-state-directory root))
               (roost--request nil "list" nil (lambda (_) (cl-incf finished))
                                (lambda (err) (setq failure err) (cl-incf finished)))))
           (let ((deadline (+ (float-time) 8)))
             (while (and (< finished 2) (< (float-time) deadline)) (accept-process-output nil .05)))
           (should (= finished 2)) (should-not failure)
           (dolist (root roots)
             (should (= (length (directory-files root nil "remote-.*\\.py")) 1))))
       (dolist (root roots) (delete-directory root t))))))

(ert-deftest roost-hosts-survive-emacs-restart ()
  (roost-test--isolated
   (let* ((root (make-temp-file "roost-hosts" t)) (roost-hosts-file (expand-file-name "hosts.json" root))
          (roost-hosts '(nil)))
     (unwind-protect
         (progn (roost--remember-host "dev") (roost--remember-host "dev")
                (setq roost--hosts-loaded nil roost--remembered-hosts nil)
                (should (equal (roost--hosts) '(nil "dev"))))
       (delete-directory root t)))))

(ert-deftest roost-local-host-survives-restart-and-legacy-files-are-repaired ()
  (roost-test--isolated
   (let* ((root (make-temp-file "roost-hosts" t))
          (roost-hosts-file (expand-file-name "hosts.json" root))
          (roost-hosts '("dev")))
     (unwind-protect
         (progn
           (roost--remember-host nil)
           (roost--remember-host "dev")
           (should (equal (with-temp-buffer (insert-file-contents roost-hosts-file) (buffer-string))
                          "[\"dev\",null]"))
           (setq roost--hosts-loaded nil roost--remembered-hosts nil)
           (should (equal (roost--hosts) '("dev" nil)))
           ;; Version 0.4 wrote the local host as {}.
           (with-temp-file roost-hosts-file (insert "[\"dev\",{},7]"))
           (setq roost--hosts-loaded nil roost--remembered-hosts nil)
           (should (equal (roost--hosts) '("dev" nil))))
       (delete-directory root t)))))

(ert-deftest roost-requests-encode-absent-values-as-null ()
  (should (equal (roost--json-encode '((base) (full . :false) (name . "x") (command . ["a"])))
                 "{\"base\":null,\"full\":false,\"name\":\"x\",\"command\":[\"a\"]}")))

(ert-deftest roost-creation-sends-branch-prefix-and-nulls ()
  (roost-test--isolated
   (let ((roost-branch-prefix "clay/") request)
     (cl-letf (((symbol-function 'hack-dir-local-variables-non-file-buffer) #'ignore)
               ((symbol-function 'roost--request) (lambda (_host _action params &rest _) (setq request params))))
       (roost-new-task "/tmp/" "task")
       (should (equal (alist-get 'branchPrefix request) "clay/"))
       (should (string-match-p "\"prompt\":null" (roost--json-encode request)))))))

(ert-deftest roost-manual-refresh-runs-after-an-in-flight-poll ()
  (roost-test--isolated
   (let ((roost-hosts '("dev")) calls)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action params success _failure)
                  (push (cons (alist-get 'full params) success) calls))))
       (roost-refresh t)
       (roost-refresh)                  ; `g' while the quiet poll is in flight
       (should (= (length calls) 1))
       (funcall (cdar calls) nil)       ; the quiet poll returns
       (should (= (length calls) 2))
       (should (eq (caar calls) t))))))

(ert-deftest roost-background-polls-back-off-from-unreachable-hosts ()
  (roost-test--isolated
   (let ((roost-hosts '("dev")) (attempts 0))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params _success failure)
                  (cl-incf attempts) (funcall failure "unreachable"))))
       (roost-refresh t)
       (roost-refresh t)
       (should (= attempts 1))
       (roost-refresh)                  ; a manual refresh always tries
       (should (= attempts 2))
       (should (= (car (gethash "dev" roost--failures)) 2))))))

(ert-deftest roost-dashboard-groups-by-project-and-summarizes-attention ()
  (roost-test--isolated
   (roost--cache-task "dev" (append '((repo . "/home/user/ledger") (startedAt . "1")
                                      (diff . "2 files changed, 10 insertions(+), 3 deletions(-)")
                                      (dirty . t) (ahead . 1) (behind . 4)
                                      (task . "Fix the parser.\nThen add tests."))
                                    (roost-test--task "1111111111111111" "permission")))
   (roost--cache-task "dev" (append '((repo . "/home/user/ledger") (startedAt . "2") (name . "totals"))
                                    (roost-test--task "2222222222222222" "running")))
   (roost--cache-task nil (append '((repo . "/Users/user/site") (name . "docs") (agent . "codex"))
                                  (roost-test--task "3333333333333333" "ready")))
   (with-temp-buffer
     (roost-dashboard-mode)
     (roost--render-dashboard)
     (let ((text (buffer-string)))
       (should (string-prefix-p "1 awaiting permission · 1 ready · 1 running\n" text))
       (should (string-match-p "^dev · ledger  ~/ledger$" text))
       (should (string-match-p "^local · site  ~/site$" text))
       (should (string-match-p "  ● fix auth  permission  [0-9a-z]+ +claude  2 files \\+10 −3 · uncommitted · ↑1 ↓4  Fix the parser\\. Then add tests\\." text))
       ;; Creation order within a project; projects sorted by host.
       (should (< (string-match "fix auth" text) (string-match "totals" text)))
       (should (< (string-match "dev · ledger" text) (string-match "local · site" text))))
     ;; Point starts on the first task, and task commands target the row.
     (should (equal (roost--field (roost--task-at-point) 'id) "1111111111111111"))
     (roost-dashboard-next-task)
     (should (equal (roost--field (roost--task-at-point) 'id) "2222222222222222"))
     (roost-dashboard-next-task)
     (should (equal (roost--field (roost--task-at-point) 'id) "3333333333333333"))
     (roost-dashboard-next-task)
     (should (equal (roost--field (roost--task-at-point) 'id) "3333333333333333"))
     ;; A redraw keeps point on the same task.
     (roost--render-dashboard)
     (should (equal (roost--field (roost--task-at-point) 'id) "3333333333333333")))
   ;; A quiet poll omits Git fields; the last full refresh's remain.
   (roost--apply-snapshot "dev" (list (append '((repo . "/home/user/ledger")) (roost-test--task "1111111111111111"))
                                      (append '((repo . "/home/user/ledger")) (roost-test--task "2222222222222222"))))
   (should (equal (roost--changes (gethash '("dev" "1111111111111111") roost--tasks))
                  "2 files +10 −3 · uncommitted · 1 ahead · 4 behind"))
   (should (equal (roost--changes '((diff . "1 file changed, 1 insertion(+)"))) "1 file +1 −0"))))

(ert-deftest roost-dashboard-columns-fit-narrow-windows ()
  (roost-test--isolated
   (let ((tasks (list (append '((agent . "codex") (diff . "3 files changed, 38 insertions(+), 1 deletion(-)") (dirty . t))
                              (roost-test--task "1111111111111111"))
                      (append '((name . "dedupe-imports")) (roost-test--task "2222222222222222")))))
     (should (equal (roost--dashboard-layout tasks 150) '(:name 14 :agent t :changes 28 :pr 0)))
     (should (plist-get (roost--dashboard-layout tasks 75) :agent))
     (should-not (plist-get (roost--dashboard-layout tasks 50) :agent))
     (should (= (plist-get (roost--dashboard-layout tasks 30) :changes) 0))
     (dolist (width '(150 100 75 60 50 45))
       (should (<= (string-width (roost--dashboard-row (car tasks) (roost--dashboard-layout tasks width) width))
                   width))))))

(ert-deftest roost-review-fixes-for-paths-layout-and-drafts ()
  (roost-test--isolated
   ;; Only the owner's home is abbreviated.
   (should (equal (roost--abbreviate-path "/home/user/app") "~/app"))
   (should (equal (roost--abbreviate-path "/home/alice/app") "/home/alice/app"))
   (should (equal (roost--abbreviate-path "/home/alice/app" "alice@dev") "~/app"))
   ;; Without any changes, dropping the agent column adds no blank column.
   (let ((tasks (list (append '((agent . "codex")) (roost-test--task "1111111111111111"))
                      (roost-test--task "2222222222222222"))))
     (should (equal (plist-get (roost--dashboard-layout tasks 45) :changes) 0)))
   (let ((default-directory "/tmp/") created)
     (save-window-excursion
       (unwind-protect
           (cl-letf (((symbol-function 'roost--create-task)
                      (lambda (&rest args) (push args created))))
             ;; An untouched draft follows the task in context.
             (roost--compose)
             (with-current-buffer roost--compose-buffer
               (setq roost--compose-fields (plist-put roost--compose-fields :directory "/old/")))
             (roost--cache-task "dev" (append '((repo . "/home/user/repo")) (roost-test--task)))
             (setq roost--current-task '("dev" "0123456789abcdef"))
             (roost--compose)
             (with-current-buffer roost--compose-buffer
               (should (string-suffix-p ":/home/user/repo/" (plist-get roost--compose-fields :directory)))
               ;; A second C-c C-c while creating does not create twice.
               (goto-char (point-max))
               (insert "Do the thing")
               (roost-compose-submit)
               (should-error (roost-compose-submit) :type 'user-error)
               (should (= (length created) 1))))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-empty-dashboard-explains-how-to-start ()
  (roost-test--isolated
   (let ((roost-hosts '(nil "dev")))
     (with-temp-buffer
       (roost-dashboard-mode)
       (roost--render-dashboard)
       (should (string-match-p "No tasks yet" (buffer-string)))
       (should (string-match-p "Watching local, dev" (buffer-string)))))))

(ert-deftest roost-task-picker-orders-by-attention-and-hides-ids ()
  (roost-test--isolated
   (roost--cache-task "dev" (append '((name . "alpha")) (roost-test--task "1111111111111111" "running")))
   (roost--cache-task "dev" (append '((name . "beta")) (roost-test--task "2222222222222222" "permission")))
   (roost--cache-task "dev" (append '((name . "beta")) (roost-test--task "3333333333333333" "stopped")))
   (let (candidates annotation)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (setq candidates (funcall table "" nil t)
                        annotation (alist-get 'annotation-function (cdr (funcall table "" nil 'metadata))))
                  (car candidates))))
       (should (equal (roost--field (roost--read-task "Task: ") 'id) "2222222222222222")))
     (should (equal candidates '("beta  dev · unknown  [222222]" "alpha  dev · unknown" "beta  dev · unknown  [333333]")))
     (should (string-match-p "permission  fix authentication" (funcall annotation (car candidates)))))))

(ert-deftest roost-task-panel-shows-prompt-changes-and-grouped-actions ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((repo . "/home/user/ledger") (diff . "1 file changed, 2 insertions(+)")
                                                  (baseRef . "main") (integrationBranch . "main")
                                                  (agentSession . "abc-123"))
                                                (roost-test--task)))))
     (cl-letf (((symbol-function 'roost--refresh-host) #'ignore))
       (save-window-excursion
         (roost-task-info task)
         (with-current-buffer "*roost: fix auth*"
           (unwind-protect
               (let ((text (buffer-string)))
                 (should (string-match-p "^fix auth   ● ready for" text))
                 (should (string-match-p "^Prompt\nfix authentication" text))
                 (should (string-match-p "^Changes\n1 file \\+2 −0" text))
                 (should (string-match-p "Finish   Pull request P    Merge and retire m    Retire x    Forget X" text))
                 (should (string-match-p "Branch       codex/roost/fix-auth-123456, from main, merges into main" text))
                 (should (string-match-p "Worktree     ~/work/fix auth" text))
                 ;; Line counts keep their colors inside the indented section.
                 (goto-char (point-min))
                 (search-forward "+2")
                 (should (memq 'roost-diff-added (ensure-list (get-text-property (1- (point)) 'face))))
                 (should (string-match-p "Conversation abc-123" text))
                 (should-not display-line-numbers))
             (kill-buffer))))))))

(ert-deftest roost-forget-removes-the-task-and-reports-what-remains ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))) messages)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
               ((symbol-function 'message) (lambda (format &rest args) (push (apply #'format format args) messages)))
               ((symbol-function 'roost--request)
                (lambda (_host action _params success &optional _failure)
                  (should (equal action "forget"))
                  (funcall success (append '((status . "forgotten") (leftBehind "branch b")) (roost-test--task))))))
       (roost-forget task)
       (should-not (roost-tasks))
       (should (string-match-p "left in place: branch b" (car messages)))))))

(ert-deftest roost-send-confirms-before-pasting-into-a-possible-permission-prompt ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "permission"))) sent asked)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action params &rest _) (setq sent params)))
               ((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) nil)))
       (should-error (roost-send task "hello") :type 'user-error)
       (should (string-match-p "asking for permission" asked))
       (should-not sent))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action params &rest _) (setq sent params)))
               ((symbol-function 'yes-or-no-p) (lambda (_) t)))
       (roost-send task "hello")
       (should (eq (alist-get 'force sent) t)))
     (setf (alist-get 'status task) "ready")
     (setq sent nil asked nil)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action params &rest _) (setq sent params)))
               ((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) t)))
       (roost-send task "hello")
       (should-not asked)
       (should-not (assq 'force sent))))))

(ert-deftest roost-update-offers-the-agent-its-conflicts ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((integrationBranch . "main")) (roost-test--task))))
         sent)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host action _params success &rest _)
                  (should (equal action "update"))
                  (funcall success (append '((update (conflicts "a.py" "b.py") (changed . t))
                                             (integrationBranch . "main"))
                                           (roost-test--task)))))
               ((symbol-function 'roost--refresh-host) #'ignore)
               ((symbol-function 'yes-or-no-p) (lambda (_) t))
               ((symbol-function 'roost-send) (lambda (_task text) (setq sent text))))
       (roost-update task)
       (should (string-match-p "merged main into this branch and Git reports conflicts in: a.py, b.py" sent))))))

(defmacro roost-test--with-send-buffers (&rest body)
  `(unwind-protect (progn ,@body)
     (dolist (buffer (buffer-list))
       (when (string-prefix-p "*roost send:" (buffer-name buffer)) (kill-buffer buffer)))))

(ert-deftest roost-agents-stuck-starting-count-as-waiting-at-a-prompt ()
  (roost-test--isolated
   (let* ((old (format-time-string "%FT%T%z" (time-subtract nil 120)))
          (new (format-time-string "%FT%T%z")))
     (roost--cache-task "dev" (append `((updatedAt . ,old) (name . "stuck")) (roost-test--task "1111111111111111" "starting")))
     (roost--cache-task "dev" (append `((updatedAt . ,new) (name . "booting")) (roost-test--task "2222222222222222" "starting")))
     (roost--cache-task "dev" (append `((updatedAt . ,new) (name . "idle")) (roost-test--task "3333333333333333" "ready")))
     (should (equal (roost--attention-status (gethash '("dev" "1111111111111111") roost--tasks)) "prompt"))
     (should (equal (roost--attention-status (gethash '("dev" "2222222222222222") roost--tasks)) "starting"))
     (should (string-prefix-p "1 at a startup prompt · 1 ready · 1 running" (roost--summary (roost-tasks))))
     (let (opened)
       (cl-letf (((symbol-function 'roost-open-task)
                  (lambda (task) (setq opened (roost--field task 'name) roost--current-task (roost--key task)))))
         (roost-next-waiting) (should (equal opened "stuck"))
         (roost-next-waiting) (should (equal opened "idle"))
         (roost-next-waiting) (should (equal opened "stuck")))))))

(ert-deftest roost-send-region-drafts-the-last-selected-line ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let (name)
      (cl-letf (((symbol-function 'roost--read-task) (lambda (_) (roost-test--task)))
                ((symbol-function 'pop-to-buffer) #'set-buffer))
        (with-temp-buffer
          (setq name (buffer-name))
          (insert "one\ntwo\nthree\n")
          (roost-send-region (point-min) (save-excursion (goto-char (point-min)) (forward-line 2) (point)))))
      (with-current-buffer "*roost send: fix auth*"
        (should (derived-mode-p 'roost-send-mode))
        (should (string-match-p (concat (regexp-quote name) ":1-2\n\none\ntwo\n") (buffer-string)))
        (should (= (point) (point-min))))))))

(ert-deftest roost-send-region-targets-the-task-owning-the-file ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let ((task (roost--cache-task "dev" (roost-test--task))) asked)
      (ignore task)
      (cl-letf (((symbol-function 'roost--read-task) (lambda (_) (setq asked t) (roost-test--task)))
                ((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--directory-host) (lambda (_) "dev")))
        (with-temp-buffer
          (setq buffer-file-name "/home/user/work/fix auth/src/a.py")
          (insert "x\n")
          (roost-send-region (point-min) (point-max))
          (should-not asked)
          (should (get-buffer "*roost send: fix auth*"))
          (with-current-buffer "*roost send: fix auth*"
            (should (string-prefix-p "\n\nsrc/a.py:1-1\n" (buffer-string)))
            (erase-buffer))
          (set-buffer-modified-p nil)
          (setq buffer-file-name "/elsewhere/b.py")
          (roost-send-region (point-min) (point-max))
          (should asked)
          (with-current-buffer "*roost send: fix auth*"
            (should (string-prefix-p "\n\n/elsewhere/b.py:1-1\n" (buffer-string))))))))))

(ert-deftest roost-send-opens-a-draft-interactively-and-keeps-text-calls ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let ((task (roost--cache-task "dev" (roost-test--task))) sent)
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--choose) (lambda (&optional _) task))
                ((symbol-function 'read-string) (lambda (&rest _) (error "no minibuffer")))
                ((symbol-function 'roost--request)
                 (lambda (_host _action params &rest _) (setq sent params))))
        (call-interactively #'roost-send)
        (should (derived-mode-p 'roost-send-mode))
        (should (string-match-p "fix auth" header-line-format))
        (should-not sent)
        (roost-send task "hello")
        (should (equal (alist-get 'text sent) "hello")))))))

(ert-deftest roost-send-draft-sends-multi-line-text-and-closes ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let ((task (roost--cache-task "dev" (roost-test--task))) sent buffer)
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--refresh-host) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore)
                ((symbol-function 'roost--request)
                 (lambda (_host _action params success &rest _)
                   (setq sent params)
                   (funcall success (roost-test--task)))))
        (roost--send-draft task)
        (setq buffer (current-buffer))
        (should-error (roost-send-submit) :type 'user-error)
        (insert "first\nsecond\n")
        (roost-send-submit)
        (should (equal (alist-get 'text sent) "first\nsecond"))
        (should-not (buffer-live-p buffer)))))))

(ert-deftest roost-send-draft-survives-failure-and-declined-confirmation ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let ((task (roost--cache-task "dev" (roost-test--task nil "permission"))) answer)
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'yes-or-no-p) (lambda (_) answer))
                ((symbol-function 'roost--request)
                 (lambda (_host _action _params _success failure) (funcall failure "boom"))))
        (roost--send-draft task)
        (insert "hello")
        (should-error (roost-send-submit) :type 'user-error)
        (should-not roost--send-sending)
        (setq answer t)
        (roost-send-submit)
        (should (buffer-live-p (current-buffer)))
        (should-not roost--send-sending)
        (should (string-match-p "boom" header-line-format))
        (should (equal (buffer-string) "hello")))))))

;; Pull requests

(defmacro roost-test--with-pr-buffers (&rest body)
  `(unwind-protect (progn ,@body)
     (dolist (buffer (buffer-list))
       (when (string-prefix-p "*roost pr:" (buffer-name buffer)) (kill-buffer buffer)))))

(defun roost-test--pr-task (&rest fields)
  (append fields '((pr . ((number . 12) (url . "https://github.com/o/r/pull/12"))))
          (roost-test--task)))

(ert-deftest roost-pr-draft-prefills-from-commits-and-prompt ()
  (roost-test--isolated
   (let ((task (roost-test--task)))
     (setf (alist-get 'name task) "fix-auth_flow")
     (should (equal (roost--pr-initial-text task '("Fix the login"))
                    "Fix the login\n\nfix authentication\n"))
     (should (equal (roost--pr-initial-text task '("One" "Two"))
                    "Fix auth flow\n\nfix authentication\n\n- One\n- Two\n"))
     (should (equal (roost--pr-initial-text task nil) "Fix auth flow\n\nfix authentication\n"))
     (setf (alist-get 'task task) "fix-auth_flow")
     (should (equal (roost--pr-initial-text task '("One" "Two")) "Fix auth flow\n\n- One\n- Two\n"))
     (should (equal (roost--pr-initial-text task nil) "Fix auth flow\n\n")))))

(ert-deftest roost-pr-commits-come-from-git-in-the-worktree ()
  (let* ((dir (make-temp-file "roost-pr" t))
         (default-directory (file-name-as-directory dir)))
    (call-process "git" nil nil nil "init" "-q" "-b" "main")
    (dolist (subject '("first" "second" "third"))
      (call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@t" "commit" "-q"
                    "--allow-empty" "-m" subject))
    (let ((base (string-trim (shell-command-to-string "git rev-parse HEAD~2"))))
      (should (equal (roost--pr-commits `((worktree . ,dir) (baseCommit . ,base)))
                     '("second" "third"))))
    (should-not (roost--pr-commits `((worktree . ,dir))))))

(ert-deftest roost-pr-draft-creates-the-pull-request-and-closes ()
  (roost-test--isolated
   (roost-test--with-pr-buffers
    (let ((task (roost--cache-task "dev" (roost-test--task))) sent buffer)
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--pr-commits) (lambda (_) '("Fix the login")))
                ((symbol-function 'roost--refresh-host) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore)
                ((symbol-function 'roost--request)
                 (lambda (_host action params success &rest _)
                   (setq sent (cons action params))
                   (funcall success (roost-test--pr-task)))))
        (roost-pr task)
        (setq buffer (current-buffer))
        (should (derived-mode-p 'roost-pr-mode))
        (should (string-prefix-p "Fix the login\n\nfix authentication" (buffer-string)))
        (goto-char (point-min))
        (delete-region (point) (line-end-position))
        (should-error (roost-pr-submit) :type 'user-error)
        (insert "Better title")
        (roost-pr-submit)
        (should (equal (car sent) "pr"))
        (should (equal (alist-get 'title (cdr sent)) "Better title"))
        (should (equal (alist-get 'body (cdr sent)) "fix authentication"))
        (should-not (alist-get 'draft (cdr sent)))
        (should-not (buffer-live-p buffer))
        (should (alist-get 'pr (gethash '("dev" "0123456789abcdef") roost--tasks))))))))

(ert-deftest roost-pr-prefix-makes-a-draft-and-failure-keeps-the-text ()
  (roost-test--isolated
   (roost-test--with-pr-buffers
    (let ((task (roost--cache-task "dev" (roost-test--task))) sent)
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--pr-commits) (lambda (_) nil))
                ((symbol-function 'roost--request)
                 (lambda (_host _action params _success failure)
                   (setq sent params)
                   (funcall failure "no remote"))))
        (roost-pr task)
        (roost-pr-submit t)
        (should (eq (alist-get 'draft sent) t))
        (should (buffer-live-p (current-buffer)))
        (should-not roost--pr-sending)
        (should (string-match-p "no remote" header-line-format))
        (should (string-prefix-p "Fix auth\n" (buffer-string))))))))

(ert-deftest roost-pr-opens-the-existing-one-in-the-browser ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--pr-task))) opened)
     (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
       (roost-pr task)
       (should (equal opened "https://github.com/o/r/pull/12"))))))

(ert-deftest roost-pr-markers-show-state-checks-and-review ()
  (let ((marker (lambda (&rest fields)
                  (let ((m (roost--pr-marker (apply #'roost-test--pr-task fields))))
                    (cons (substring-no-properties m) (get-text-property 0 'face m))))))
    (should (equal (funcall marker) '("#12" . roost-pr-open)))
    (should (equal (funcall marker '(prStatus . ((state . "OPEN") (checks . ((passing . 3))))))
                   '("#12 ✓" . roost-pr-open)))
    (should (equal (funcall marker '(prStatus . ((state . "OPEN") (draft . t)
                                                 (review . "CHANGES_REQUESTED")
                                                 (checks . ((passing . 3) (failing . 1) (pending . 1))))))
                   '("#12 ✗ !" . roost-pr-draft)))
    (should (equal (car (funcall marker '(prStatus . ((state . "OPEN") (review . "APPROVED")
                                                      (checks . ((pending . 2)))))))
                   "#12 … +"))
    (should (equal (funcall marker '(prStatus . ((state . "MERGED") (checks . ((failing . 1))))))
                   '("#12" . roost-pr-merged)))
    (should (equal (funcall marker '(prStatus . ((state . "CLOSED")))) '("#12" . roost-pr-closed)))
    (should (equal (roost--pr-marker (roost-test--task)) ""))))

(ert-deftest roost-pr-shows-in-the-dashboard-and-panel ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--pr-task
                                          '(repo . "/home/user/ledger")
                                          '(prStatus . ((state . "OPEN") (review . "APPROVED")
                                                        (checks . ((passing . 2) (failing . 1)))))))))
     (with-temp-buffer
       (roost-dashboard-mode)
       (roost--render-dashboard)
       (should (string-match-p "ready +[0-9a-z]+ +#12 ✗ \\+  " (buffer-string))))
     (cl-letf (((symbol-function 'roost--refresh-host) #'ignore))
       (save-window-excursion
         (roost-task-info task)
         (with-current-buffer "*roost: fix auth*"
           (unwind-protect
               (let ((text (buffer-string)))
                 (should (string-match-p "^Pull request\n  #12  https://github.com/o/r/pull/12\nOpen · 1 failing, 2 passing · approved" text))
                 (should-not (string-match-p "Merged on GitHub" text))
                 (goto-char (point-min))
                 (search-forward "#12")
                 (should (button-at (1- (point))))
                 (puthash '("dev" "0123456789abcdef")
                          (roost-test--pr-task '(host . "dev") '(prStatus . ((state . "MERGED"))))
                          roost--tasks)
                 (roost--render-task-info)
                 (should (string-match-p "Merged on GitHub\\. x retires this task" (buffer-string))))
             (kill-buffer))))))))

(ert-deftest roost-quiet-refresh-retains-pull-request-status ()
  (roost-test--isolated
   (roost--cache-task "dev" (roost-test--pr-task '(prStatus . ((state . "OPEN")))))
   (roost--apply-snapshot "dev" (list (roost-test--pr-task)))
   (should (alist-get 'prStatus (gethash '("dev" "0123456789abcdef") roost--tasks)))))

(ert-deftest roost-tab-bar-workspaces-follow-tasks ()
  (roost-test--isolated
   (let ((roost-workspace 'tab-bar)
         (task (roost--cache-task "dev" (roost-test--task))))
     (unwind-protect
         (progn
           (roost--activate-workspace task)
           (should (equal (roost--current-workspace) "dev/fix auth"))
           (should (member "dev/fix auth" (roost--tabs)))
           ;; Back in the task's tab, commands target it.
           (with-temp-buffer
             (setq default-directory "/tmp/")
             (should (equal (roost--key (roost--task-at-point)) (roost--key task))))
           (roost--activate-workspace task)
           (should (= (seq-count (apply-partially #'equal "dev/fix auth") (roost--tabs)) 1))
           (roost--retired-workspace task)
           (should-not (member "dev/fix auth" (roost--tabs))))
       (while (cdr (roost--tabs)) (tab-bar-close-tab))))))

(ert-deftest roost-workspace-backend-is-chosen-automatically ()
  (roost-test--isolated
   (let ((roost-workspace 'auto) (persp-mode nil) (tab-bar-mode nil))
     (should-not (roost--workspace-backend))
     (setq tab-bar-mode t)
     (should (eq (roost--workspace-backend) 'tab-bar))
     (setq persp-mode t)
     (cl-letf (((symbol-function 'persp-current-name) (lambda () "main")))
       (should (eq (roost--workspace-backend) 'perspective))
       (let ((roost-use-perspectives nil))
         (should (eq (roost--workspace-backend) 'tab-bar))))
     (let ((roost-workspace nil)) (should-not (roost--workspace-backend))))))

(ert-deftest roost-doctor-reports-checks-and-connection-fixes ()
  (roost-test--isolated
   (let ((roost-hosts '("dev" "far")) (roost-default-agent "claude"))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (host action _params success failure)
                  (should (equal action "doctor"))
                  (if (equal host "dev")
                      (funcall success '(((name . "tmux") (ok . t) (detail . "tmux 3.7c"))
                                         ((name . "Claude") (ok) (detail . "/bin/claude 2.1")
                                          (hint . "Run `claude` once on this host to sign in"))
                                         ((name . "Pi") (ok) (detail . "pi not found")
                                          (hint . "Install Pi"))
                                         ((name . "Codex") (ok) (detail . "codex-cli 0.150.1")
                                          (hint . "Upgrade to Codex 0.160.0"))
                                         ((name . "GitHub CLI") (ok) (optional . t) (detail . "not found")
                                          (hint . "Optional: install gh"))
                                         ((name . "Mystery") (ok) (optional) (detail . "broken")
                                          (hint . "Fix it"))))
                    (funcall failure "far: Permission denied (publickey)."))))
               ((symbol-function 'pop-to-buffer) #'ignore))
       (unwind-protect
           (progn
             (roost-doctor)
             (with-current-buffer "*roost doctor*"
               (let ((text (buffer-string)))
                 (should (string-match-p "✓ tmux +tmux 3.7c" text))
                 (should (string-match-p "✗ Claude.*\n +Run `claude` once on this host to sign in" text))
                 (should (string-match-p "– Pi.*\n +Optional: needed only for Pi tasks" text))
                 (should (string-match-p "– Codex +codex-cli 0.150.1\n +For Codex tasks: Upgrade to Codex 0.160.0" text))
                 (should (string-match-p "– GitHub CLI +not found\n +Optional: install gh" text))
                 (should (string-match-p "✗ Mystery +broken" text))
                 (should (string-match-p "✗ SSH and Python +far: Permission denied" text))
                 (should (string-match-p "ssh-copy-id far" text))
                 (should (string-match-p "· Workspaces" text)))))
         (kill-buffer "*roost doctor*"))))))

(ert-deftest roost-evil-users-get-working-keys ()
  (let (states)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (mode state) (push (cons mode state) states))))
      (with-temp-buffer (roost-dashboard-mode))
      (with-temp-buffer (roost-compose-mode))
      (let ((roost-evil-state nil)) (with-temp-buffer (roost-task-info-mode))))
    (should (eq (alist-get 'roost-dashboard-mode states) 'emacs))
    (should (eq (alist-get 'roost-compose-mode states) 'insert))
    ;; nil reaches Evil, which clears any earlier registration.
    (should (equal (assq 'roost-task-info-mode states) '(roost-task-info-mode))))
  (should (eq (lookup-key roost-dashboard-mode-map "j") 'roost-dashboard-next-task))
  (should (eq (lookup-key roost-dashboard-mode-map "k") 'roost-dashboard-previous-task))
  (should (eq (lookup-key roost-dashboard-mode-map "K") 'roost-stop)))

(provide 'roost-test)
