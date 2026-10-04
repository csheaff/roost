;;; roost-test.el --- Task protocol and UI tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'roost)
(defvar persp-modestring-short nil)
(defvar persp-modestring-dividers nil)

(defmacro roost-test--isolated (&rest body)
  `(let ((roost--tasks (make-hash-table :test 'equal))
         (roost-projects-file (expand-file-name "projects.json" (make-temp-file "roost-projects" t)))
         (roost--projects-loaded t) (roost--remembered-projects nil)
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
       (roost-next-waiting) (should (equal (car opened) "a"))
       (roost-next-waiting) (should (equal (car opened) "b"))
       (puthash "a" "offline" roost--errors)
       (roost-next-waiting) (should (equal (car opened) "b"))))))

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
   (roost--cache-task nil (append '((repo . "/Users/me/site") (name . "docs") (agent . "codex"))
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
                 (should (string-match-p "Finish   Merge and retire m    Retire x    Forget X" text))
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

(ert-deftest roost-send-region-reports-the-last-selected-line ()
  (roost-test--isolated
   (let (sent name)
     (cl-letf (((symbol-function 'roost--read-task) (lambda (_) (roost-test--task)))
               ((symbol-function 'roost-send) (lambda (_task text) (setq sent text))))
       (with-temp-buffer
         (setq name (buffer-name))
         (insert "one\ntwo\nthree\n")
         (roost-send-region (point-min) (save-excursion (goto-char (point-min)) (forward-line 2) (point))))
       (should (string-prefix-p (concat name ":1-2\n") sent))))))

(provide 'roost-test)
