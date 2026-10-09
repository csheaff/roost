;;; roost-test.el --- Task protocol and UI tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'roost)
(defvar persp-mode nil)
(defvar persp-modestring-short nil)
(defvar persp-modestring-dividers nil)
(defvar evil-want-keybinding)

(defmacro roost-test--isolated (&rest body)
  `(let ((roost--tasks (make-hash-table :test 'equal))
         (roost-projects-file (expand-file-name "projects.json" (make-temp-file "roost-projects" t)))
         (roost--projects-loaded t) (roost--remembered-projects nil)
         (user-login-name "user")
         (roost--statuses (make-hash-table :test 'equal))
         (roost--seen (make-hash-table :test 'equal))
         (roost--errors (make-hash-table :test 'equal))
         (roost--installed (make-hash-table :test 'equal))
         (roost--refreshing (make-hash-table :test 'equal))
         (roost--revisions (make-hash-table :test 'equal))
         (roost--full-refresh-pending (make-hash-table :test 'equal))
         (roost--failures (make-hash-table :test 'equal))
         (roost--hosts-loaded t) (roost--remembered-hosts nil)
         (roost-notes-file (expand-file-name "notes.json" (make-temp-file "roost-notes" t)))
         (roost--notes nil) (roost--notes-loaded t)
         (roost--requests nil) (roost-notify nil) (roost--current-task nil))
     (set-frame-parameter nil 'roost-task nil)
     ;; Seeing an agent is recorded on its host too; tests that check it say so.
     (cl-letf (((symbol-function 'roost--record-seen) #'ignore))
       (unwind-protect (progn ,@body)
         (set-frame-parameter nil 'roost-task nil)))))

(defvar-local roost-test--tmux nil
  "Plist of the stubbed tmux-control identity of the current buffer.")

(defmacro roost-test--with-tmux-buffers (&rest body)
  "Run BODY with tmux-control's buffer accessors reading `roost-test--tmux'."
  `(cl-letf (((symbol-function 'tmux-control-buffer-host) (lambda () (plist-get roost-test--tmux :host)))
             ((symbol-function 'tmux-control-buffer-socket-name) (lambda () (plist-get roost-test--tmux :socket)))
             ((symbol-function 'tmux-control-buffer-session) (lambda () (plist-get roost-test--tmux :session)))
             ((symbol-function 'tmux-control-active-pane) (lambda () (plist-get roost-test--tmux :pane)))
             ((symbol-function 'tmux-control-window-id) (lambda () (plist-get roost-test--tmux :window))))
     ,@body))

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

(defconst roost-test--reply
  "## Summary\n\n---\n\nFixed the **auth** bug in `login.py`.\n\nSecond line.")

(ert-deftest roost-strip-markdown-removes-wrapping-markers-only ()
  (pcase-dolist (`(,in . ,out)
                 '(("*it* and _it_" . "it and it")
                   ("**b** __b__ ***both***" . "b b both")
                   ("(**b**), _x_." . "(b), x.")
                   ("snake_case_name and __init__.py" . "snake_case_name and __init__.py")
                   ("a * b and 2*3 and a ** b" . "a * b and 2*3 and a ** b")
                   ("`**`" . "**")
                   ("use `snake_*x*_` or **`code`**" . "use snake_*x*_ or code")
                   ("`a` and `b`" . "a and b")
                   ("``a ` b`` and ```c```" . "a ` b and c")
                   ("`` `x` ``" . "`x`")))
    (should (equal (roost--strip-markdown in) out))))

(ert-deftest roost-last-message-summary-skips-noise ()
  (should (equal (roost--last-message-summary `((lastMessage . ,roost-test--reply)))
                 "Fixed the auth bug in login.py."))
  (should-not (roost--last-message-summary '((lastMessage . "# Title\n\n--- ..."))))
  (should-not (roost--last-message-summary (roost-test--task))))

(ert-deftest roost-last-message-summary-recognizes-only-real-headings ()
  (let ((summary (lambda (text) (roost--last-message-summary `((lastMessage . ,text))))))
    (should (equal (funcall summary "#123 is fixed\n\nDetails") "#123 is fixed"))
    (should (equal (funcall summary "#hashtag\nmore") "#hashtag"))
    (should (equal (funcall summary "###### Six\n####### seven\nBody") "####### seven"))
    (should (equal (funcall summary "#\nBody") "Body"))
    (should (equal (funcall summary "Summary\n=======\nAll fixed") "All fixed"))
    (should (equal (funcall summary "Summary\r\n---\r\nAll fixed") "All fixed"))
    (should (equal (funcall summary "Fixed it.\n\n---\nNext") "Fixed it."))))

(ert-deftest roost-dashboard-shows-last-message-or-prompt ()
  (roost-test--isolated
   (let* ((with (append `((lastMessage . ,roost-test--reply)) (roost-test--task)))
          (without (roost-test--task "fedcba9876543210")))
     (dolist (task (list with without))
       (let ((row (roost--dashboard-row task (roost--dashboard-layout (list task) 120) 120)))
         (if (eq task with)
             (progn (should (string-match-p "Fixed the auth bug in login\\.py\\." row))
                    (should-not (string-match-p "fix authentication" row)))
           (should (string-match-p "fix authentication" row))))))))

(ert-deftest roost-a-permission-request-says-what-it-asks ()
  (roost-test--isolated
   (let* ((asking (roost--cache-task "dev" (append `((request . "Asks to run make test")
                                                     (lastMessage . ,roost-test--reply))
                                                   (roost-test--task nil "permission"))))
          ;; A request left in the record after the agent moved on is stale.
          (moved-on (append '((request . "Asks to run make test")) (roost-test--task "fedcba9876543210" "running")))
          (row (lambda (task) (roost--dashboard-row task (roost--dashboard-layout (list task) 120) 120))))
     (should (string-match-p "Asks to run make test" (funcall row asking)))
     (should-not (string-match-p "Asks to" (funcall row moved-on)))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key asking))
       (roost--render-task-info)
       (should (string-match-p "^Waiting for your answer\nAsks to run make test\n\nAgent's latest reply$"
                               (buffer-string))))
     ;; The notification names it, rather than the agent's last words.
     (let (body)
       (cl-letf (((symbol-function 'roost--request)
                  (lambda (_host _action _params success _failure) (funcall success asking)))
                 ((symbol-function 'roost--notify) (lambda (_title text &rest _) (setq body text))))
         (roost--notify-attention "dev" asking "permission"))
       (should (equal body "dev · Asks to run make test"))))))

(ert-deftest roost-task-panel-shows-latest-reply ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append `((lastMessage . ,roost-test--reply))
                                                (roost-test--task)))))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key task))
       (roost--render-task-info)
       (let ((text (buffer-string)))
         (should (< (string-match "^fix auth " text) (string-match "^Agent's latest reply$" text)
                    (string-match "^Changes$" text) (string-match "^Prompt$" text)))
         (should (string-match-p "^Agent's latest reply\n## Summary\n" text))
         (should (equal (get-text-property (string-match "Fixed the" text) 'line-prefix text) "  "))
         (should (string-match-p "^Fixed the auth bug in login\\.py\\.\n" text))
         (should-not (string-match-p "\\*\\*\\|`" text)))))))

(ert-deftest roost-task-panel-folds-a-long-prompt ()
  (should (equal (roost--prompt-preview "Fix it.") "Fix it."))
  (should (equal (roost--prompt-preview "Fix it.\n\nDetails follow.") "Fix it."))
  (let ((preview (roost--prompt-preview (concat (make-string 500 ?a) " tail"))))
    (should (string-suffix-p "…" preview))
    (should (< (length preview) 410)))
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((task . "Fix the login.\n\nRun the tests afterwards."))
                                                (roost-test--task)))))
     (with-temp-buffer
       (setq roost--buffer-task-key (roost--key task))
       (roost--render-task-info)
       (should (string-match-p "^Fix the login\\.\nShow the whole prompt$" (buffer-string)))
       (should-not (string-match-p "Run the tests" (buffer-string)))
       (goto-char (point-min))
       (search-forward "Show the whole")
       (push-button (1- (point)))
       (should (string-match-p "Run the tests afterwards" (buffer-string)))))))

(ert-deftest roost-task-panel-previews-long-replies-and-collapses-new-ones ()
  (roost-test--isolated
   (let* ((reply (mapconcat (lambda (n) (format "Progress item %d: handled the edge case." n))
                           (number-sequence 1 30) "\n\n"))
          (task (roost--cache-task "dev" (append `((lastMessage . ,reply)) (roost-test--task)))))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key task))
       (cl-letf (((symbol-function 'roost--task-info-width) (lambda () 40)))
         (roost--render-task-info)
         (should (string-match-p "Show the whole reply" (buffer-string)))
         (should-not (string-match-p "Progress item 30" (buffer-string)))
         (let ((preview (buffer-substring-no-properties
                         (progn (goto-char (point-min)) (search-forward "Agent's latest reply\n") (point))
                         (progn (search-forward "Show the whole reply") (match-beginning 0)))))
           (should (<= (length (split-string preview "\n" t)) 6)))
         (search-backward "Show the whole reply")
         (push-button)
         (should (string-match-p "Progress item 30" (buffer-string)))
         (should (string-match-p "Collapse reply" (buffer-string)))
         ;; Quiet refreshes retain the explicit expansion choice.
         (roost--render-task-info)
         (should (string-match-p "Progress item 30" (buffer-string)))
         (goto-char (point-min))
         (search-forward "Collapse reply")
         (push-button (1- (point)))
         (should-not (string-match-p "Progress item 30" (buffer-string)))
         (goto-char (point-min))
         (search-forward "Show the whole reply")
         (push-button (1- (point)))
         (setf (alist-get 'lastMessage task) (concat reply "\n\nA new response arrived."))
         (roost--render-task-info)
         (should-not roost--expanded-reply)
         (should-not (string-match-p "A new response arrived" (buffer-string)))
         (should (string-match-p "^Changes$" (buffer-string)))
         (should (string-match-p "^Actions$" (buffer-string))))))))

(ert-deftest roost-task-panel-previews-wrap-long-tokens-and-preserve-short-replies ()
  (should (equal (roost--reply-preview "Done.\nTests passed." 40) "Done.\nTests passed."))
  (dolist (reply (list (make-string 1000 ?a)
                       (make-string 500 ?界)
                       (mapconcat #'number-to-string (number-sequence 1 20) "\n")))
    (let ((preview (roost--reply-preview reply 40)))
      (should (string-suffix-p "…" preview))
      (should (<= (length (split-string preview "\n")) 6))
      (should (seq-every-p (lambda (line) (<= (string-width line) 38))
                          (split-string preview "\n")))))
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append `((lastMessage . ,(make-string 1000 ?a)))
                                                (roost-test--task)))))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key task))
       (roost--render-task-info)
       (should (string-match-p (make-string 1000 ?a) (buffer-string)))
       (should-not (string-match-p "Show the whole reply" (buffer-string)))))))

(ert-deftest roost-quiet-refresh-retains-last-message ()
  (roost-test--isolated
   (roost--cache-task "dev" (append '((lastMessage . "All done")) (roost-test--task)))
   (roost--apply-snapshot "dev" (list (roost-test--task)))
   (should (equal (roost--field (car (roost-tasks)) 'lastMessage) "All done"))
   (roost--apply-snapshot "dev" (list (append '((lastMessage . "Newer")) (roost-test--task))))
   (should (equal (roost--field (car (roost-tasks)) 'lastMessage) "Newer"))))

(defmacro roost-test--without-inspect (&rest body)
  "Run BODY with notification inspections failing at once."
  `(cl-letf (((symbol-function 'roost--request)
              (lambda (_host _action _params _success failure) (funcall failure "offline"))))
     ,@body))

(ert-deftest roost-notifications-say-what-the-agent-finished ()
  (roost-test--isolated
   (let* ((roost-notify t) notices
          (roost-notify-function (lambda (title body) (push (list title body) notices))))
     (cl-letf (((symbol-function 'roost--redraw) #'ignore)
               ((symbol-function 'roost--request)
                (lambda (_host action _params success _failure)
                  (should (equal action "inspect"))
                  (funcall success (append '((lastMessage . "## Done\n\nFixed the **login** bug."))
                                           (roost-test--task nil "ready"))))))
       (roost--cache-task "dev" (roost-test--task nil "running"))
       (roost--cache-task "dev" (roost-test--task nil "ready"))
       (should (equal notices '(("Roost: fix auth — ready" "dev · Fixed the login bug."))))
       (should (equal (roost--field (car (roost-tasks)) 'lastMessage)
                      "## Done\n\nFixed the **login** bug."))))))

(ert-deftest roost-a-turn-that-failed-says-why-and-that-the-agent-waits ()
  ;; At a usage limit every agent's turn fails while the agents run on,
  ;; and the panel suggested `s', which refuses a running agent.
  (roost-test--isolated
   (let* ((roost-notify t) notices
          (roost-notify-function (lambda (title body) (push (list title body) notices)))
          (error "Its turn ended on an API error (rate_limit): You've hit your limit")
          (failed (roost--cache-task "dev" (append `((live . t) (error . ,error))
                                                   (roost-test--task nil "failed")))))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key failed))
       (roost--render-task-info)
       (should (string-match-p "^fix auth   ● error for" (buffer-string)))
       (should (string-match-p "Its last turn failed, and the agent waits. RET opens it to try again."
                               (buffer-string)))
       (should-not (string-match-p "resumes" (buffer-string)))
       (should (string-match-p (concat "Last error: " (regexp-quote error)) (buffer-string)))
       ;; An agent that exited is resumed.
       (roost--cache-task "dev" (append '((live)) (roost-test--task nil "failed")))
       (roost--render-task-info)
       (should (string-match-p "The agent has failed. RET shows its last output; s resumes" (buffer-string))))
     ;; Its status says the agent waits: an error, not a failure to resume.
     (should (equal (roost--display-status failed) "error"))
     (should (roost--waiting-p failed))
     (roost--notify-attention "dev" failed "failed")
     (should (equal notices `(("Roost: fix auth — error" ,(concat "dev · " error))))))))

(ert-deftest roost-notifies-once-and-not-on-initial-attachment ()
  (roost-test--isolated
   (roost-test--without-inspect
   (let* ((roost-notify t) notices
         (roost-notify-function (lambda (title _body) (push title notices))))
     (roost--cache-task "dev" (roost-test--task nil "ready"))
     (should-not notices)
     (roost--cache-task "dev" (roost-test--task nil "running"))
     (roost--cache-task "dev" (roost-test--task nil "permission"))
     (roost--cache-task "dev" (roost-test--task nil "permission"))
     (should (= (length notices) 1))))))

(ert-deftest roost-does-not-notify-about-the-agent-you-are-watching ()
  (roost-test--isolated
   (roost-test--without-inspect
    (let* ((roost-notify t) notices
           (roost-notify-function (lambda (title _body) (push title notices)))
           (focused t))
      (roost--cache-task "dev" (roost-test--task nil "running"))
      (with-temp-buffer
        (setq-local roost-test--tmux '(:host "dev" :socket "main" :session "roost-123456" :pane "%12"))
        (save-window-excursion
          (set-window-buffer (selected-window) (current-buffer))
          (roost-test--with-tmux-buffers
           (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) focused)))
             ;; Its terminal is in front of you: no notification.
             (roost--cache-task "dev" (roost-test--task nil "permission"))
             (should-not notices)
             ;; With Emacs in the background, you hear about it.
             (setq focused nil)
             (roost--cache-task "dev" (roost-test--task nil "running"))
             (roost--cache-task "dev" (roost-test--task nil "permission"))
             (should (= (length notices) 1))))))))))

(ert-deftest roost-notifies-on-fast-turns-that-finish-between-polls ()
  (roost-test--isolated
   (roost-test--without-inspect
   (let* ((roost-notify t) notices
          (roost-notify-function (lambda (title _body) (push title notices)))
          (finished (append '((lastEvent . "Stop")) (roost-test--task))))
     (roost--cache-task "dev" (roost-test--task nil "ready"))
     (setf (alist-get 'updatedAt finished) "2026-10-03T20:00:01+00:00")
     (roost--cache-task "dev" finished)
     (roost--cache-task "dev" (copy-tree finished))
     (should (= (length notices) 1))))))

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
       ;; Only b, which has a new task, goes on to fetch its Git statistics.
       (should (equal (hash-table-keys roost--refreshing) '("b")))
       (should (equal (car (car callbacks)) "b"))))))

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

(ert-deftest roost-ssh-requests-share-a-connection-unless-disabled ()
  (let* ((root (make-temp-file "rs" t))
         (roost-state-directory (expand-file-name "s" root))
         (roost-ssh-share-connections t)
         (argv (roost--python-command "dev" "pass")))
    (if (< (+ (string-bytes roost-state-directory) 5 40 17) 104)
        (progn
          (should (member "ControlMaster=auto" argv))
          (should (member (concat "ControlPath=" roost-state-directory "/ssh-%C") argv))
          (should (file-directory-p roost-state-directory)))
      (should-not (member "ControlMaster=auto" argv)))
    ;; A state directory too long for a socket path connects without sharing.
    (let ((roost-state-directory (expand-file-name (make-string 60 ?d) root)))
      (should-not (member "ControlMaster=auto" (roost--python-command "dev" "pass"))))
    (let ((roost-state-directory (make-temp-file "/tmp/rs" t)))
      (unwind-protect
          (progn
            (should (member (concat "ControlPath=" roost-state-directory "/ssh-%C")
                            (roost--ssh-share-options)))
            (let ((roost-ssh-share-connections nil))
              (should-not (member "ControlMaster=auto" (roost--python-command "dev" "pass")))))
        (delete-directory roost-state-directory t)))))

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
       ;; Claude's command now lives with the others; the older setting still wins.
       (let ((roost-claude-command '("claude"))
             (roost-agent-commands '(("claude" "claude" "--model" "opus"))))
         (roost-new-task "/tmp/" "claude" nil nil "claude")
         (should (equal (alist-get 'command (car requests)) ["claude" "--model" "opus"]))
         (should-not (assq 'session (pop requests))))
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
     (setq-local roost-test--tmux '(:host "dev" :socket "main" :session "roost-123456" :pane "%13"))
     (roost-test--with-tmux-buffers
      (should (equal (roost--field (roost--task-at-point) 'host) "dev"))))))

(ert-deftest roost-a-terminal-is-its-own-tasks-after-tmux-restarts ()
  ;; A restarted tmux server numbers panes afresh, so an agent that died
  ;; with the old one still lists the pane ID of a newer task's agent.
  (roost-test--isolated
   (roost--cache-task "dev" (append '((name . "alpha") (session . "roost-p-111111") (paneId . "%0")
                                      (status . "crashed"))
                                    (roost-test--task "1111111111111111")))
   (roost--cache-task "dev" (append '((name . "beta") (session . "roost-p-222222") (paneId . "%0"))
                                    (roost-test--task "2222222222222222")))
   (with-temp-buffer
     (setq-local roost-test--tmux '(:host "dev" :socket "main" :session "roost-p-222222" :pane "%0"))
     (roost-test--with-tmux-buffers
      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) t)))
        (should (equal (roost--field (roost--task-at-point) 'id) "2222222222222222"))
        (save-window-excursion
          (set-window-buffer (selected-window) (current-buffer))
          (should (equal (roost--field (roost--watched-task) 'id) "2222222222222222"))))))))

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
                      (lambda (directory name base prompt agent on-success on-failure &optional _extra)
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
               (funcall failure "no such host\nssh: details")
               (should (string-match-p "Could not create the task: no such host · " header-line-format))
               (should-not (string-match-p "\n" header-line-format))
               (should (buffer-live-p (current-buffer)))))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-compose-starts-from-the-region-or-org-entry ()
  (roost-test--isolated
   (let ((default-directory "/tmp/") (transient-mark-mode t))
     (save-window-excursion
       (unwind-protect
           (progn
             (with-temp-buffer
               (org-mode)
               (insert "* Notes\n** TODO Speed up the importer\nSCHEDULED: <2026-10-05 Mon>\n"
                       ":PROPERTIES:\n:ID: x\n:END:\nIt reads the file twice.\n** Next\n")
               (goto-char (point-min))
               (search-forward "twice")
               (roost--compose))
             (with-current-buffer roost--compose-buffer
               (should (equal (roost--compose-prompt) "Speed up the importer\n\nIt reads the file twice."))
               (should (= (point) (point-max))))
             (kill-buffer roost--compose-buffer)
             ;; An agenda line stands for its entry.
             (let ((notes (generate-new-buffer "notes.org")))
               (unwind-protect
                   (let ((marker (with-current-buffer notes
                                   (org-mode)
                                   (insert "* TODO Cache the parse\nKeep it per file.\n")
                                   (copy-marker (point-min)))))
                     (require 'org-agenda)
                     (with-temp-buffer
                       (org-agenda-mode)
                       (insert (propertize "  TODO Cache the parse\n" 'org-hd-marker marker))
                       (goto-char (point-min))
                       (roost--compose)))
                 (kill-buffer notes)))
             (with-current-buffer roost--compose-buffer
               (should (equal (roost--compose-prompt) "Cache the parse\n\nKeep it per file.")))
             (kill-buffer roost--compose-buffer)
             (with-temp-buffer
               (emacs-lisp-mode)
               (insert "(defun a ()\n  1)\n(defun b ()\n  2)\n")
               (goto-char (point-min))
               (forward-line 2)
               (set-mark (point))
               (goto-char (point-max))
               (activate-mark)
               (roost--compose))
             (with-current-buffer roost--compose-buffer
               (should (string-match-p "\\`.*:3-4\n\n(defun b ()\n  2)\\'" (roost--compose-prompt)))
               ;; Point waits above the quoted code for the instructions.
               (should (= (point) roost--compose-body))
               (insert "Make b return 3.")
               (should (string-prefix-p "Make b return 3." (roost--compose-prompt))))
             ;; A written draft is kept rather than replaced.
             (with-temp-buffer
               (insert "other text")
               (set-mark (point-min))
               (activate-mark)
               (roost--compose))
             (with-current-buffer roost--compose-buffer
               (should (string-prefix-p "Make b return 3." (roost--compose-prompt)))))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-compose-starts-from-a-github-issue ()
  (roost-test--isolated
   (let ((default-directory "/tmp/") created asked)
     (save-window-excursion
       (unwind-protect
           (cl-letf (((symbol-function 'roost--request)
                      (lambda (host action params success &optional _failure)
                        (setq asked (list host action (alist-get 'directory params)))
                        (funcall success
                                 (vector '((number . 12) (title . "CSV import crashes")
                                           (body . "Quoted commas split fields.")
                                           (url . "https://github.com/o/r/issues/12")
                                           (labels . ["bug"]))
                                         '((number . 9) (title . "Docs") (body . "")
                                           (url . "https://github.com/o/r/issues/9") (labels . []))))))
                     ((symbol-function 'completing-read)
                      (lambda (_prompt choices &rest _) (car (nth (if created 1 0) choices))))
                     ((symbol-function 'roost--create-task)
                      (lambda (directory name base prompt agent _success _failure &optional extra)
                        (setq created (list directory name base prompt agent extra)))))
             (roost--compose)
             (with-current-buffer roost--compose-buffer
               (should-error (roost-compose-set-issue) :type 'user-error)
               (setq roost--compose-fields (plist-put roost--compose-fields :directory "/ssh:dev:/repo/"))
               (roost-compose-set-issue)
               (should (equal asked '("dev" "issues" "/repo/")))
               (should (equal (roost--compose-prompt)
                              "CSV import crashes\n\nQuoted commas split fields.\n\nThis is GitHub issue #12: https://github.com/o/r/issues/12"))
               (should (string-match-p "Issue    #12 CSV import crashes  C-c C-t · the pull request will close it"
                                       (buffer-string)))
               (should (string-match-p "Name     12-csv-import-crashes" (buffer-string)))
               (roost-compose-submit)
               (should (equal (nth 5 created)
                              '((issue (number . 12) (title . "CSV import crashes")
                                       (url . "https://github.com/o/r/issues/12")))))
               ;; A written prompt keeps its text and gains the issue below.
               (goto-char (point-max))
               (insert "\nAlso handle tabs.")
               (setq roost--compose-submitting nil)
               (roost-compose-set-issue)
               (should (string-match-p "Also handle tabs\\.\n\nCSV import crashes" (roost--compose-prompt)))))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-issue-tasks-show-the-issue-and-close-it ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((issue (number . 12) (title . "CSV import crashes")
                                                         (url . "https://github.com/o/r/issues/12")))
                                                (roost-test--task)))))
     (should (string-suffix-p "\n\nCloses #12\n" (roost--pr-initial-text task '("Fix CSV quoting"))))
     (should-not (string-match-p "Closes" (roost--pr-initial-text task '("Fix CSV quoting\n\nFixes #12."))))
     (with-temp-buffer
       (setq roost--buffer-task-key (roost--key task))
       (roost--render-task-info)
       (should (string-match-p "^Issue\n  #12  CSV import crashes$" (buffer-string)))))))

(ert-deftest roost-dispatch-names-the-task-of-the-buffer-it-was-opened-from ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))))
     (with-temp-buffer
       (setq roost--buffer-task-key (roost--key task))
       (let ((transient--original-buffer (current-buffer)))
         (with-temp-buffer
           (should (string-match-p "\\`Task fix auth (ready)\\'"
                                   (substring-no-properties (roost--dispatch-task-description))))))))
   (let ((transient--original-buffer nil))
     (with-temp-buffer
       (should (equal (roost--dispatch-task-description) "Task (chosen when needed)"))))
   ;; The 0.2 alias of roost-dispatch to roost-new-task must not shadow the menu.
   (should (get 'roost-dispatch 'transient--prefix))
   (should-not (eq (indirect-function 'roost-dispatch) (indirect-function 'roost-new-task)))
   (should (eq (lookup-key roost-dashboard-mode-map "h") 'roost-dispatch))
   (should (eq (lookup-key roost-task-info-mode-map "h") 'roost-dispatch))))

(ert-deftest roost-mode-line-counts-agents-waiting ()
  (roost-test--isolated
   (should-not (roost--mode-line-count))
   (roost--cache-task "dev" (roost-test--task "1111111111111111" "running"))
   (should-not (roost--mode-line-count))
   (roost--cache-task "dev" (roost-test--task "2222222222222222" "ready"))
   (let ((count (roost--mode-line-count)))
     (should (equal (substring-no-properties count) " Roost:1 "))
     (should (eq (get-text-property 1 'face count) 'roost-status-ready)))
   (roost--cache-task "dev" (roost-test--task "3333333333333333" "permission"))
   (let ((count (roost--mode-line-count)))
     (should (equal (substring-no-properties count) " Roost:2 "))
     (should (eq (get-text-property 1 'face count) 'roost-status-permission)))
   (let ((global-mode-string '("" display-time-string)) (roost-watch-interval 3600))
     (unwind-protect
         (progn
           (roost-watch-mode 1)
           (roost-watch-mode 1)
           (should (equal global-mode-string (list "" 'display-time-string roost--mode-line-entry)))
           ;; Shown only while `roost-mode-line-count' is on.
           (should (eq (car roost--mode-line-entry) 'roost-mode-line-count))
           (should (equal (substring-no-properties (eval (cadr (cadr roost--mode-line-entry)) t))
                          " Roost:2 ")))
       (roost-watch-mode -1))
     (should (equal global-mode-string '("" display-time-string))))))

(ert-deftest roost-sidebar-lists-tasks-compactly ()
  (roost-test--isolated
   (let ((roost--current-task nil) (roost-watch-mode t))
     (roost--cache-task "dev" (append '((name . "budget-alerts") (repo . "/srv/ledger"))
                                      (roost-test--task "1111111111111111" "permission")))
     (roost--cache-task "dev" (append '((name . "a-task-with-a-very-long-name-indeed") (repo . "/srv/ledger"))
                                      (roost-test--task "2222222222222222" "running")))
     (setq roost--current-task '("dev" "1111111111111111"))
     (with-temp-buffer
       (roost-sidebar-list-mode)
       (roost--render-sidebar)
       (let ((lines (split-string (buffer-string) "\n")))
         (should (equal (substring-no-properties (car lines)) "Roost  1 waiting"))
         (let ((roost-watch-mode nil))
           (roost--render-sidebar)
           (should (string-prefix-p "Roost  1 waiting  paused\n" (buffer-string))))
         (roost--render-sidebar)
         ;; Each project's heading ends with a + that starts a task in it.
         (should (member (concat "dev · ledger" (make-string 17 ?\s) "+") lines))
         ;; The current task is marked; statuses are right-aligned.
         (should (member "▸● budget-alerts    permission" lines))
         (should (= (string-width "▸● budget-alerts    permission") roost-sidebar-width))
         ;; Long names are cut to fit, keeping the status when it fits.
         (should (seq-some (lambda (line) (and (string-prefix-p " ● a-task" line)
                                                (string-match-p "…" line)
                                                (<= (string-width line) roost-sidebar-width)))
                           lines)))
       ;; Task commands find the task on the line, as in the dashboard.
       (goto-char (point-min))
       (search-forward "budget-alerts")
       (should (equal (roost--field (roost--task-at-point) 'id) "1111111111111111"))
       (search-forward "a-task")
       (let ((help (get-text-property (1- (point)) 'help-echo)))
         (should (string-match-p "a-task-with-a-very-long-name-indeed" help))
         (should (string-match-p "dev · /srv/ledger" help)))
       ;; On the heading, a new task's draft starts in that project.
       (goto-char (point-min))
       (search-forward "dev · ledger")
       (should (string-suffix-p ":dev:/srv/ledger/" (roost--compose-default-directory nil nil)))
       (let (started)
         (cl-letf (((symbol-function 'roost-new-task)
                    (lambda () (interactive) (setq started (roost--compose-default-directory nil nil)))))
           (search-forward "+")
           (push-button (1- (point))))
         (should (string-suffix-p ":dev:/srv/ledger/" started)))))))

(ert-deftest roost-sidebar-mode-pins-a-left-window ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let ((roost-watch-interval 3600))
       (cl-letf (((symbol-function 'roost-refresh) #'ignore)
                 ((symbol-function 'frame-width) (lambda (&rest _) 200)))
         (unwind-protect
             (progn
               (roost-sidebar-mode 1)
               (should (memq #'roost--layout-changed
                             (default-value 'window-configuration-change-hook)))
               (let ((window (get-buffer-window roost--sidebar-buffer)))
                 (should (eq (window-parameter window 'window-side) 'left))
                 (should (window-dedicated-p window))
                 (should (eq (window-parameter window 'mode-line-format) 'none))
                 (should (eq (window-parameter window 'tab-line-format) 'none))
                 ;; It survives C-x 1 from the main window.
                 (select-window (window-main-window))
                 (delete-other-windows)
                 (should (window-live-p window))
                 ;; Opening a task from the sidebar uses the main window.
                 (select-window window)
                 (roost--leave-side-window)
                 (should-not (window-parameter (selected-window) 'window-side))))
           (roost-sidebar-mode -1)
           (roost-watch-mode -1)))
       (should-not (get-buffer-window roost--sidebar-buffer))
       (should-not roost-sidebar-mode)))))

(ert-deftest roost-loading-adds-no-hooks ()
  (let ((window-configuration-change-hook nil)
        (window-size-change-functions nil)
        (after-make-frame-functions nil)
        (persp-activated-hook nil))
    (load (expand-file-name "roost.el" (file-name-directory (locate-library "roost"))) nil t)
    (should-not (default-value 'window-configuration-change-hook))
    (should-not (default-value 'window-size-change-functions))
    (should-not after-make-frame-functions)
    (should-not persp-activated-hook)))

(ert-deftest roost-layout-changes-are-followed-after-redisplay ()
  ;; Changing windows during redisplay's change hooks would hide the
  ;; resize from other packages; Roost waits for a timer instead.
  (let ((roost--layout-timer nil) synced)
    (cl-letf (((symbol-function 'roost--sync-all-frames) (lambda () (setq synced t))))
      (roost--layout-changed)
      (roost--layout-changed)
      (should (timerp roost--layout-timer))
      (should-not synced)
      (let ((timer roost--layout-timer))
        (cancel-timer timer)
        (funcall (timer--function timer)))
      (should synced)
      (should-not roost--layout-timer))))

(ert-deftest roost-unloading-stops-following-the-layout ()
  (let ((window-configuration-change-hook nil))
    (roost--watch-layout)
    (should (memq #'roost--layout-changed (default-value 'window-configuration-change-hook)))
    (cl-letf (((symbol-function 'advice-remove) #'ignore))
      (roost-unload-function))
    (should-not (default-value 'window-configuration-change-hook))))

(ert-deftest roost-dashboard-leaves-the-sidebar-to-the-user ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let ((roost-sidebar-mode nil))
       (cl-letf (((symbol-function 'roost-watch-mode) #'ignore)
                 ((symbol-function 'roost-refresh) #'ignore))
         (roost-status)
         (should-not roost-sidebar-mode)
         (should-not (get-buffer-window roost--sidebar-buffer)))))))

(ert-deftest roost-side-windows-skip-narrow-and-special-frames ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let ((roost-sidebar-mode t) (roost-task-panel-mode nil))
       (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 100)))
         (roost--sync-side-windows))
       (should-not (get-buffer-window roost--sidebar-buffer))
       (should (roost--side-frame-p))
       ;; Such as Ediff's control frame.
       (cl-letf (((symbol-function 'frame-parameter)
                  (lambda (_frame parameter) (eq parameter 'unsplittable))))
         (should-not (roost--side-frame-p)))))))

(ert-deftest roost-task-panel-docks-beside-the-terminal-when-there-is-room ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let ((task (roost--cache-task "dev" (roost-test--task)))
           (roost-workspace nil) (roost-task-panel-width 44) (roost-task-panel-mode t))
       (set-frame-parameter nil 'roost-task (roost--key task))
       (cl-letf (((symbol-function 'roost--refresh-host) #'ignore))
         (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 160)))
           (roost--sync-side-windows))
         (let ((window (roost--task-panel-window)))
           (should window)
           (should (equal (buffer-local-value 'roost--buffer-task-key (window-buffer window))
                          (roost--key task))))
         ;; Too narrow: the panel goes away and the terminal keeps its room.
         (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 30)))
           (roost--sync-side-windows))
         (should-not (roost--task-panel-window))
         ;; It returns with room, unless the mode is off.
         (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 160)))
           (let ((roost-task-panel-mode nil))
             (roost--sync-side-windows)
             (should-not (roost--task-panel-window)))
           (roost--sync-side-windows)
           (should (roost--task-panel-window))))))))

(ert-deftest roost-task-panel-needs-room-in-the-widest-main-window ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let ((task (roost--cache-task "dev" (roost-test--task)))
           (roost-workspace nil) (roost-task-panel-mode t))
       (set-frame-parameter nil 'roost-task (roost--key task))
       ;; A frame wide enough overall, but split into 90-column windows.
       (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 200))
                 ((symbol-function 'window-body-width) (lambda (&rest _) 90)))
         (roost--sync-side-windows))
       (should-not (roost--task-panel-window))))))

(ert-deftest roost-task-panel-follows-the-current-workspace ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((a (roost--cache-task "dev" (roost-test--task)))
            (b (roost--cache-task "dev" (append '((name . "add tags"))
                                                (roost-test--task "1111111111111111"))))
            (roost-workspace 'perspective) (persp-mode t) (roost-task-panel-mode t)
            (current (roost--perspective-name a)))
       (cl-letf (((symbol-function 'persp-current-name) (lambda () current))
                 ((symbol-function 'window-body-width) (lambda (&rest _) 160))
                 ((symbol-function 'roost--refresh-host) #'ignore))
         (cl-flet ((shown () (when-let* ((window (roost--task-panel-window)))
                               (buffer-local-value 'roost--buffer-task-key (window-buffer window)))))
           (roost--sync-side-windows)
           (should (equal (shown) (roost--key a)))
           (setq current (roost--perspective-name b))
           (roost--sync-side-windows)
           (should (equal (shown) (roost--key b)))
           ;; Switching tasks keeps the panel's window to itself.
           (should (window-dedicated-p (roost--task-panel-window)))
           ;; A workspace that belongs to no task has no panel.
           (setq current "main")
           (roost--sync-side-windows)
           (should-not (shown))))))))

(ert-deftest roost-same-named-tasks-get-their-own-panels ()
  (roost-test--isolated
   (let ((a (roost--cache-task "dev" (roost-test--task)))
         (b (roost--cache-task "dev" (roost-test--task "1111111111111111")))
         (c (roost--cache-task "lab" (roost-test--task "2222222222222222"))))
     (should (equal (mapcar #'roost--task-info-buffer-name (list a b c))
                    '("*roost: fix auth on dev (012345)*" "*roost: fix auth on dev (111111)*"
                      "*roost: fix auth on lab*"))))))

(ert-deftest roost-task-panel-q-turns-it-off-until-asked-back ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((task (roost--cache-task "dev" (roost-test--task)))
            (other (roost--cache-task "dev" (roost-test--task "1111111111111111")))
            (roost-workspace nil) (roost-task-panel-mode t) (main (selected-window)))
       (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 160))
                 ((symbol-function 'roost--refresh-host) #'ignore))
         (set-frame-parameter nil 'roost-task (roost--key task))
         (roost--sync-side-windows)
         (select-window (roost--task-panel-window))
         (roost-task-info-quit)
         (should-not roost-task-panel-mode)
         (should-not (roost--task-panel-window))
         (should (eq main (selected-window)))
         ;; Other tasks, and saved layouts that held a panel, go without.
         (set-frame-parameter nil 'roost-task (roost--key other))
         (roost--sync-side-windows)
         (should-not (roost--task-panel-window))
         (display-buffer-in-side-window (roost--task-info-buffer task)
                                        (roost--side-window-alist 'right 44))
         (roost--sync-side-windows)
         (should-not (roost--task-panel-window))
         ;; I brings it back for the frame's task, keeping focus.
         (roost-task-panel-mode 1)
         (should (eq main (selected-window)))
         (should (equal (buffer-local-value 'roost--buffer-task-key
                                            (window-buffer (roost--task-panel-window)))
                        (roost--key other))))))))

(ert-deftest roost-task-panel-wraps-in-a-narrow-window ()
  (with-temp-buffer
    (roost-task-info-mode)
    ;; Emacs truncates lines in windows under 50 columns unless told not to.
    (should-not truncate-partial-width-windows)
    (should-not truncate-lines)
    (should word-wrap)))

(ert-deftest roost-task-panel-draws-in-order-in-a-window-not-selected ()
  ;; Measuring the panel's window must not move point while it is drawn.
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((task (roost--cache-task "dev" (roost-test--task)))
            (buffer (roost--task-info-buffer task))
            (other (split-window-right)))
       (unwind-protect
           (progn
             (set-window-buffer other buffer)
             (with-current-buffer buffer
               (roost--render-task-info)
               (roost--render-task-info)
               (should (string-prefix-p "fix auth" (buffer-string)))
               (should (< (string-search "Actions" (buffer-string))
                          (string-search "Details" (buffer-string))))))
         (kill-buffer buffer))))))

(ert-deftest roost-task-panel-redraws-keep-the-scroll-position ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((reply (mapconcat (lambda (n) (format "Line %d of the reply." n))
                              (number-sequence 1 60) "\n"))
            (task (roost--cache-task "dev" (append `((lastMessage . ,reply)) (roost-test--task))))
            (buffer (roost--task-info-buffer task))
            (window (selected-window)))
       (unwind-protect
           (with-current-buffer buffer
             (set-window-buffer window buffer)
             (roost--render-task-info)
             (goto-char (point-min))
             (search-forward "Line 30 ")
             (set-window-start window (line-beginning-position))
             (set-window-point window (point))
             (roost--render-task-info)
             (should (string-prefix-p "Line 30 " (buffer-substring (window-start window)
                                                                   (line-end-position))))
             (should (equal (buffer-substring (line-beginning-position) (point)) "Line 30 ")))
         (kill-buffer buffer))))))
(ert-deftest roost-task-panel-lists-changed-files-that-open-their-diffs ()
  (let* ((files '(((path . "notes.py") (added . 10) (deleted . 3))
                  ((path . "docs/a/very/long/path/to/the/guide.md") (added . 1) (deleted . 0))
                  ((path . "logo.png"))
                  ((path . "notes.md") (untracked . t))))
         (task (append `((files . ,files)) (roost-test--task)))
         shown)
    (with-temp-buffer
      (roost--insert-changed-files task 40)
      (let ((lines (split-string (buffer-string) "\n" t)))
        (should (equal (car lines) "  notes.py  +10 −3"))
        (should (member "  logo.png  binary" lines))
        (should (member "  notes.md  new" lines))
        ;; A long path keeps its end and fits.
        (should (seq-some (lambda (line) (and (string-match-p "….*guide\\.md  \\+1 −0" line)
                                              (<= (string-width line) 40)))
                          lines)))
      (goto-char (point-min))
      (search-forward "notes.py")
      (cl-letf (((symbol-function 'roost--diff-file) (lambda (_task file) (setq shown file))))
        (push-button (1- (point))))
      (should (equal (alist-get 'path shown) "notes.py")))
    ;; Wide characters are cut by their width.
    (with-temp-buffer
      (roost--insert-changed-files
       (append '((files ((path . "文档/说明/非常长的文件名称说明文档.md") (added . 1) (deleted . 0))))
               (roost-test--task))
       30)
      (should (string-match-p "…" (buffer-string)))
      (should (<= (string-width (car (split-string (buffer-string) "\n"))) 30)))
    ;; Beyond a dozen, the rest are summed up.
    (with-temp-buffer
      (roost--insert-changed-files
       (append `((files . ,(mapcar (lambda (n) `((path . ,(format "f%d" n)) (added . 1) (deleted . 0)))
                                   (number-sequence 1 15))))
               (roost-test--task))
       60)
      (should (string-match-p "and 3 more" (buffer-string))))))

(ert-deftest roost-task-panel-flows-actions-in-a-narrow-window ()
  (with-temp-buffer
    (roost--insert-narrow-actions 40 roost--task-actions)
    (let ((lines (split-string (buffer-string) "\n" t)))
      (should (seq-every-p (lambda (line) (<= (string-width line) 40)) lines))
      (should (string-match-p "RET Agent · t Shell" (buffer-string)))
      (should (string-match-p "m Merge and retire" (buffer-string))))))

(ert-deftest roost-discarding-says-what-is-lost-and-wants-the-name-to-lose-it ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "ready")))
         (told '((commits . 2) (changes . 1) (commit . "abc123")))
         acted asked)
     (cl-letf (((symbol-function 'roost--request-wait)
                (lambda (_host action parameters &rest _)
                  (should (equal action "discard"))
                  (should (eq (alist-get 'dryRun parameters) t))
                  `((discard ,@told))))
               ((symbol-function 'roost--act)
                (lambda (_task action parameters &rest _) (push (cons action parameters) acted)))
               ((symbol-function 'read-string)
                (lambda (prompt &rest _) (setq asked prompt) "fix auth")))
       (roost-discard task)
       (should (string-match-p "loses 2 commits no other branch has and 1 uncommitted file" asked))
       (should (equal acted '(("discard" (expect . "abc123")))))
       ;; Another name: nothing happens.
       (setq acted nil)
       (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "fix")))
         (roost-discard task))
       (should-not acted)
       ;; Nothing to lose: a plain question.
       (setq told '((commits . 0) (changes . 0) (commit . "abc123")))
       (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                 ((symbol-function 'read-string) (lambda (&rest _) (error "Not asked to type"))))
         (roost-discard task))
       (should (equal acted '(("discard" (expect . "abc123")))))
       ;; x on a task holding work merged nowhere offers to discard it.
       (setq acted nil)
       (let ((unmerged (roost--cache-task "dev" (append '((ahead . 1)) (roost-test--task nil "ready"))))
             asked-first)
         (cl-letf (((symbol-function 'y-or-n-p)
                    (lambda (prompt &rest _) (unless asked-first (setq asked-first prompt)) t)))
           (roost-retire unmerged))
         (should (string-match-p "work not merged into its branch" asked-first)))
       (should (equal (caar acted) "discard"))
       ;; With nothing to lose, x retires.
       (setq acted nil)
       (let ((merged (roost--cache-task "dev" (append '((ahead . 0) (dirty)) (roost-test--task nil "ready")))))
         (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
           (roost-retire merged)))
       (should (equal (caar acted) "retire"))
       ;; Not while its agent works.
       (should-error (roost-retire (roost--cache-task "dev" (roost-test--task nil "running"))) :type 'user-error)))))

(ert-deftest roost-a-forgotten-host-is-no-longer-watched ()
  (roost-test--isolated
   (let* ((roost-hosts '(nil))
          (roost-hosts-file (make-temp-file "roost-hosts" nil ".json"))
          (roost--hosts-loaded nil))
     (unwind-protect
         (progn
           (roost--write-json-list roost-hosts-file '("old-box" "dev"))
           (roost--cache-task "old-box" (roost-test--task nil "ready"))
           (should (member "old-box" (roost--hosts)))
           (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
             (roost-forget-host "old-box"))
           (should-not (member "old-box" (roost--hosts)))
           (should (member "dev" (roost--hosts)))
           (should-not (roost-tasks))
           ;; A poll already on its way doesn't bring its tasks back.
           (cl-letf (((symbol-function 'roost--request)
                      (lambda (_host _action _params success &rest _)
                        (funcall success (list (roost-test--task nil "ready"))))))
             (roost--refresh-host "old-box" t))
           (should-not (roost-tasks))
           ;; And stays forgotten after a restart.
           (setq roost--hosts-loaded nil roost--remembered-hosts nil)
           (should (equal (roost--hosts) '(nil "dev"))))
       (delete-file roost-hosts-file)))))

(defvar server-process)
(defvar server-socket-dir)
(defvar server-name)

(ert-deftest roost-a-notification-click-opens-its-task ()
  (roost-test--isolated
   (let* ((task (roost--cache-task "dev" (roost-test--task nil "ready")))
          (invocation-directory (file-name-as-directory (make-temp-file "roost-emacs" t)))
          (client (expand-file-name "bin/emacsclient" invocation-directory))
          (server-process (make-pipe-process :name "roost-test-server" :noquery t))
          (server-socket-dir "/tmp/emacs501") (server-name "server")
          opened)
     (unwind-protect
         (progn
           (make-directory (file-name-directory client))
           (write-region "" nil client nil 'silent)
           (set-file-modes client #o755)
           (let ((arguments (roost--terminal-notifier-arguments "Roost: fix auth — ready" "dev · done" task)))
             (should (equal (seq-take arguments 4) '("-title" "Roost: fix auth — ready" "-message" "dev · done")))
             (should (equal (cadr (member "-group" arguments)) "roost-dev-0123456789abcdef"))
             (let ((command (split-string-shell-command (cadr (member "-execute" arguments)))))
               (should (equal (seq-take command 4)
                              (list client "--socket-name" "/tmp/emacs501/server" "--no-wait")))
               ;; What the click evaluates opens the task.
               (cl-letf (((symbol-function 'roost-open-task) (lambda (task) (setq opened task)))
                         ((symbol-function 'select-frame-set-input-focus) #'ignore))
                 (eval (read (car (last command))) t))))
           (should (equal (roost--field opened 'id) "0123456789abcdef"))
           ;; Without a server, a click can't reach Emacs.
           (let ((server-process nil))
             (should-not (member "-execute" (roost--terminal-notifier-arguments "t" "b" task)))))
       (delete-process server-process)
       (delete-directory invocation-directory t)))))

(ert-deftest roost-work-in-the-agents-own-worktree-shows-and-holds-the-task ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((live . t) (ahead . 1) (diff . "")
                                                  (agentWork ((path . "/repo/.claude/worktrees/probe")
                                                              (branch . "worktree-probe")
                                                              (ahead . 2) (dirty . t))))
                                                (roost-test--task nil "ready"))))
         opened)
     (should-not (roost--action-applies-p task 'roost-merge-retire))
     (should-not (roost--action-applies-p task 'roost-retire))
     (should (string-match-p "worktree of its own" (roost--next-step task)))
     ;; A quiet poll, without Git statistics, keeps it.
     (roost--cache-task "dev" (append '((live . t)) (roost-test--task nil "ready")))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key task))
       (roost--render-task-info)
       (should (string-match-p "^Its agent's own worktrees\n  worktree-probe  2 commits not on this task's branch, uncommitted changes$"
                               (buffer-string)))
       (goto-char (point-min))
       (search-forward "worktree-probe")
       (cl-letf (((symbol-function 'magit-status) (lambda (directory) (setq opened directory)))
                 ((symbol-function 'require) (lambda (&rest _) t))
                 ((symbol-function 'tramp-find-method) (lambda (&rest _) "ssh")))
         (push-button (1- (point))))
       (should (equal opened "/ssh:dev:/repo/.claude/worktrees/probe/"))))))

(ert-deftest roost-switching-to-a-tasks-session-opens-the-task ()
  ;; tmux-control's session switcher showed it inside the workspace you were in.
  (roost-test--isolated
   (let (opened)
     (roost--cache-task "dev" (append '((session . "roost-p-111111")) (roost-test--task "1111111111111111")))
     (roost--cache-task "dev" (append '((session . "roost-shared")) (roost-test--task "2222222222222222")))
     (roost--cache-task "dev" (append '((session . "roost-shared")) (roost-test--task "3333333333333333")))
     (cl-letf (((symbol-function 'roost-open-task) (lambda (task) (setq opened (roost--field task 'id)))))
       (should (roost--switch-session "dev" "main" "roost-p-111111"))
       (should (equal opened "1111111111111111"))
       ;; Not a task's own: tmux-control switches as usual.
       (setq opened nil)
       (should-not (roost--switch-session "dev" "main" "roost-shared"))
       (should-not (roost--switch-session "dev" "main" "notes"))
       (should-not (roost--switch-session nil "main" "roost-p-111111"))
       (should-not opened)))))

(ert-deftest roost-the-next-step-fits-how-the-agent-ended ()
  (roost-test--isolated
   (should (string-match-p "RET or s resumes"
                           (roost--next-step (roost--cache-task "dev" (append '((live)) (roost-test--task nil "stopped"))))))
   ;; RET shows an exited agent's last output; it doesn't resume it.
   (should (string-match-p "RET shows its last output; s resumes"
                           (roost--next-step (roost--cache-task "dev" (append '((live)) (roost-test--task nil "exited"))))))
   (should (string-match-p "try its last prompt again"
                           (roost--next-step (roost--cache-task "dev" (append '((live . t)) (roost-test--task nil "failed"))))))
   (should (string-match-p "worktree is gone"
                           (roost--next-step (roost--cache-task "dev" (append '((live) (worktreeMissing . t))
                                                                               (roost-test--task nil "stopped"))))))))

(ert-deftest roost-forgetting-a-task-in-error-stops-its-agent-first ()
  ;; Its agent waits after a failed turn; the host refuses to forget it running.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((live . t)) (roost-test--task nil "failed")))) actions)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (string-prefix-p "Stop " prompt)))
               ((symbol-function 'roost--request)
                (lambda (_host action _params success &optional _failure)
                  (push action actions)
                  (funcall success (append `((status . ,(if (equal action "stop") "stopped" "forgotten")))
                                           (roost-test--task))))))
       (roost-forget task)
       (should (equal (reverse actions) '("stop" "forget")))))))

(ert-deftest roost-retire-offers-to-discard-when-the-host-knows-better ()
  ;; Roost's Git statistics can lag: the host refuses, and x offers to discard.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "ready"))) discarded)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
               ((symbol-function 'roost-discard) (lambda (task) (setq discarded (roost--field task 'id))))
               ((symbol-function 'roost--request)
                (lambda (_host _action _params _success failure)
                  (funcall failure "Task branch has unmerged commits; merge it (m) first, discard it, or forget the task to keep its branch"))))
       (roost-retire task))
     (should (equal discarded "0123456789abcdef")))))

(ert-deftest roost-a-merge-under-way-in-a-task-says-so-until-it-is-done ()
  ;; Declining to have the agent resolve an update's conflicts left them,
  ;; while the panel still said the integration branch had moved on.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((live . t) (behind . 1) (dirty . t) (integrationBranch . "main")
                                                  (merging (conflicts "ledger.py")))
                                                (roost-test--task nil "ready")))))
     (should (string-match-p "Finish merging main" (roost--next-step task)))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key task))
       (roost--render-task-info)
       (should (string-match-p "Merging main into it conflicts in ledger.py" (buffer-string)))
       (should-not (string-match-p "has moved on" (buffer-string)))
       ;; A quiet poll keeps it; a full one that finds none clears it.
       (roost--cache-task "dev" (append '((live . t)) (roost-test--task nil "ready")))
       (should (roost--field (gethash (roost--key task) roost--tasks) 'merging))
       (roost--cache-task "dev" (append '((live . t) (merging)) (roost-test--task nil "ready")))
       (should-not (roost--field (gethash (roost--key task) roost--tasks) 'merging))))))

(ert-deftest roost-menus-offer-what-the-task-can-do-now ()
  ;; The right-click and menu-bar menus offered everything, as the panel did.
  (roost-test--isolated
   (let ((stopped (roost--cache-task "dev" (append '((live)) (roost-test--task nil "stopped")))))
     (cl-letf (((symbol-function 'roost--task-at-point) (lambda () stopped)))
       (should-not (roost--menu-applies-p 'roost-stop))
       (should (roost--menu-applies-p 'roost-resume)))
     ;; No task at point: the command will ask which.
     (cl-letf (((symbol-function 'roost--task-at-point) (lambda () (user-error "No task"))))
       (should (roost--menu-applies-p 'roost-stop)))
     (should (seq-every-p (lambda (item) (or (stringp item) (memq :active (append item nil))))
                          roost--task-menu-items)))))

(ert-deftest roost-doctor-says-how-it-notifies ()
  (let ((roost-notify-function nil) (system-type 'darwin))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((line (roost--doctor-notifications)))
        (should (eq (nth 1 line) 'optional))
        (should (string-match-p "brew install terminal-notifier" (nth 3 line)))))
    (cl-letf (((symbol-function 'executable-find) (lambda (name &rest _) (equal name "terminal-notifier")))
              ((symbol-function 'roost--emacsclient-command) (lambda (&rest _) "emacsclient")))
      (should (eq (nth 1 (roost--doctor-notifications)) t)))))

(ert-deftest roost-a-task-offers-what-it-can-do-now ()
  ;; A stopped task's panel offered Stop, Shell and Send, which its host refuses.
  (roost-test--isolated
   (let* ((applies (lambda (task) (mapcar #'cadr (seq-mapcat #'cdr (roost--applicable-actions task)))))
          (stopped (roost--cache-task "dev" (append '((live)) (roost-test--task nil "stopped"))))
          (working (roost--cache-task "dev" (append '((live . t) (ahead . 0) (dirty))
                                                    (roost-test--task "1111111111111111" "running"))))
          (finished (roost--cache-task "dev" (append '((live . t) (ahead . 2))
                                                     (roost-test--task "2222222222222222" "ready"))))
          (merged (roost--cache-task "dev" (append '((live . t) (ahead . 2) (prStatus (state . "MERGED")))
                                                   (roost-test--task "3333333333333333" "ready")))))
     (should (equal (funcall applies stopped) '("RET" "f" "r" "D" "u" "P" "m" "x" "X" "s")))
     (should (string-match-p "resumes its conversation" (roost--next-step stopped)))
     ;; At work: nothing to merge or retire, and no resuming it.
     (should (equal (funcall applies working) '("RET" "t" "f" "e" "r" "D" "u" "X" "K")))
     (should-not (roost--next-step working))
     ;; Finished with commits: merge it, or discard it with x.
     (should (member "m" (funcall applies finished)))
     (should (member "x" (funcall applies finished)))
     (should (string-match-p "merges it" (roost--next-step finished)))
     ;; Merged on GitHub: retire it.
     (should (member "x" (funcall applies merged)))
     (should-not (member "m" (funcall applies merged)))
     (should (string-match-p "retires it" (roost--next-step merged)))
     ;; The menu greys out the same.
     (let ((transient--original-buffer (current-buffer)))
       (cl-letf (((symbol-function 'roost--task-at-point) (lambda () stopped)))
         (should (roost--stop-inapt-p))
         (should-not (roost--resume-inapt-p))
         ;; Every task entry of the menu has its predicate.
         (should (seq-every-p #'fboundp
                              (mapcar (lambda (action)
                                        (intern (format "roost--%s-inapt-p"
                                                        (string-remove-prefix "roost-" (symbol-name (nth 2 action))))))
                                      (seq-mapcat #'cdr roost--task-actions)))))))))

(ert-deftest roost-sidebar-opens-in-a-live-window-when-the-main-area-is-split ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (split-window-below)
     (let ((sidebar (display-buffer-in-side-window (get-buffer-create roost--sidebar-buffer)
                                                   '((side . left) (window-width . 20)))))
       (select-window sidebar)
       (roost--leave-side-window)
       (should (window-live-p (selected-window)))
       (should-not (window-parameter (selected-window) 'window-side))))))

(ert-deftest roost-hidden-sidebar-stays-hidden-after-restoring-a-tab ()
  (roost-test--isolated
   (save-window-excursion
     (let ((roost-watch-interval 3600) (roost-workspace 'tab-bar)
           (original-tab-bar-mode tab-bar-mode))
       (cl-letf (((symbol-function 'roost-refresh) #'ignore)
                 ((symbol-function 'frame-width) (lambda (&rest _) 200)))
         (unwind-protect
             (progn
               (tab-bar-mode 1)
               (roost-sidebar-mode 1)
               (tab-bar-new-tab)
               ;; The layout hook does this at the next redisplay.
               (roost--sync-side-windows)
               (should (get-buffer-window roost--sidebar-buffer))
               (roost-sidebar-mode -1)
               (tab-bar-select-tab 1)
               (roost--sync-side-windows)
               (should-not (get-buffer-window roost--sidebar-buffer))
               (tab-bar-select-tab 2)
               (roost--sync-side-windows)
               (should-not (get-buffer-window roost--sidebar-buffer)))
           (roost-sidebar-mode -1)
           (roost-watch-mode -1)
           (while (cdr (roost--tabs)) (tab-bar-close-tab))
           (unless original-tab-bar-mode (tab-bar-mode -1))))))))

(ert-deftest roost-sidebar-marker-follows-manual-workspace-switches ()
  (roost-test--isolated
   (let* ((a (roost--cache-task "dev" (roost-test--task)))
          (b (roost--cache-task "dev" (roost-test--task "1111111111111111")))
          (roost--current-task (roost--key a)) (roost-workspace 'perspective)
          (persp-mode t))
     (cl-letf (((symbol-function 'persp-current-name) (lambda () (roost--perspective-name b))))
       (should (string-prefix-p " " (roost--sidebar-row a 30)))
       (should (string-prefix-p "▸" (roost--sidebar-row b 30)))))))

(ert-deftest roost-files-from-the-sidebar-leaves-the-side-window ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let ((task (roost--cache-task "dev" (roost-test--task)))
           (roost-workspace nil) opened-in)
       (select-window (display-buffer-in-side-window (get-buffer-create roost--sidebar-buffer)
                                                      '((side . left) (window-width . 20))))
       (cl-letf (((symbol-function 'dired) (lambda (&rest _) (setq opened-in (selected-window)))))
         (roost-files task))
       (should (window-live-p opened-in))
       (should-not (window-parameter opened-in 'window-side))))))

(ert-deftest roost-request-wait-returns-results-and-signals-failures ()
  (cl-letf (((symbol-function 'roost--request)
             (lambda (_host _action _params success &optional _failure)
               (run-at-time 0 nil success '(1 2)))))
    (should (equal (roost--request-wait "dev" "issues" nil 5) '(1 2))))
  (cl-letf (((symbol-function 'roost--request)
             (lambda (_host _action _params _success &optional failure)
               (funcall failure "gh is not installed"))))
    (should (equal (cadr (should-error (roost--request-wait "dev" "issues" nil 5) :type 'user-error))
                   "gh is not installed"))))

(ert-deftest roost-org-entries-link-to-the-tasks-they-start ()
  (roost-test--isolated
   (let ((default-directory "/tmp/") (notes (generate-new-buffer "notes.org")))
     (require 'org-agenda)
     (save-window-excursion
       (unwind-protect
           (cl-letf (((symbol-function 'roost--create-task)
                      (lambda (_directory _name _base _prompt _agent success _failure &optional _extra)
                        (funcall success (roost--cache-task
                                          "dev" (roost-test--task "abcdefabcdef0001" "starting"))))))
             (with-current-buffer notes
               (org-mode)
               (insert "* TODO Speed up the importer\nIt reads the file twice.\n* Other\n")
               (goto-char (point-min))
               (forward-line 1)
               (roost--compose))
             (with-current-buffer roost--compose-buffer
               (setq roost--compose-fields (plist-put roost--compose-fields :directory "/ssh:dev:/repo/"))
               (roost-compose-submit))
             (with-current-buffer notes
               (goto-char (point-min))
               (should (equal (org-entry-get nil "ROOST_TASK") "abcdefabcdef0001"))
               ;; Commands on the entry act on its task; other entries don't.
               (forward-line 1)
               (should (equal (roost--field (roost--task-at-point) 'id) "abcdefabcdef0001"))
               (search-forward "* Other")
               (should-not (equal (roost--field (ignore-errors (roost--task-at-point)) 'id)
                                  "abcdefabcdef0001")))
             ;; So does the entry's agenda line.
             (let ((marker (with-current-buffer notes (copy-marker (point-min)))))
               (with-temp-buffer
                 (org-agenda-mode)
                 (insert (propertize "  TODO Speed up the importer\n" 'org-hd-marker marker))
                 (goto-char (point-min))
                 (should (equal (roost--field (roost--task-at-point) 'id) "abcdefabcdef0001"))))
             ;; Linking can be turned off.
             (let ((roost-org-link-tasks nil))
               (with-current-buffer notes
                 (goto-char (point-max))
                 (insert "* Unlinked\n")
                 (forward-line -1)
                 (roost--org-link (point-marker) '((id . "ffff")))
                 (should-not (org-entry-get nil "ROOST_TASK")))))
         (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer))
         (with-current-buffer notes (set-buffer-modified-p nil))
         (kill-buffer notes))))))

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
  (should (equal (roost--name-from-prompt "") ""))
  ;; An apostrophe joins, rather than splits off a stray letter.
  (should (equal (roost--name-from-prompt "List the notes command's options") "list-notes-commands-options"))
  (should (equal (roost--name-from-prompt "Don’t crash on empty files") "dont-crash-empty-files"))
  (should (equal (roost--name-from-prompt "Off-by-one scroll: cursor-relative full-screen repaint")
                 "off-by-one-scroll-cursor-relative"))
  (should (equal (roost--name-from-prompt "-- --- leading dashes") "leading-dashes"))
  (should (equal (roost--name-from-prompt (make-string 60 ?x)) (make-string 40 ?x)))
  ;; A summary first line names the task; repeats are dropped.
  (should (equal (roost--name-from-prompt "Capitalize greetings\n\ngreet() in greet.py returns")
                 "capitalize-greetings"))
  (should (equal (roost--name-from-prompt "Fix\nthe greet greet.py tests") "fix-greet-py-tests")))

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

(ert-deftest roost-display-task-reuses-only-an-untiled-terminal-window ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((task (roost-test--task))
            (code (generate-new-buffer " *roost-test-code*"))
            (terminal (generate-new-buffer " *roost-test-terminal*"))
            (origin (selected-window)) (other (split-window-right))
            tiled sent)
       (unwind-protect
           (progn
             (with-current-buffer terminal
               (setq-local roost-test--tmux '(:socket "main" :session "roost-123456" :window "@9" :pane "%12")))
             (set-window-buffer origin code) (set-window-buffer other terminal)
             (dlet ((features (cons 'tmux-control features)))
               (roost-test--with-tmux-buffers
                (cl-letf (((symbol-function 'roost--activate-workspace) #'ignore)
                          ((symbol-function 'tmux-control-tiled-p) (lambda () tiled))
                          ((symbol-function 'tmux-control-connect-or-switch) #'ignore)
                          ((symbol-function 'tmux-control-send-command) (lambda (command) (push command sent)))
                          ((symbol-function 'tmux-control-select-pane) #'ignore))
                  ;; A tiled pane of the task's window stays in its grid.
                  (setq tiled t)
                  (roost--display-task task)
                  (should (eq (selected-window) origin))
                  (setq tiled nil)
                  (roost--display-task task)
                  (should (eq (selected-window) other))
                  (should (equal sent '("select-window -t @9" "select-window -t @9")))))))
         (mapc #'kill-buffer (list code terminal)))))))

(ert-deftest roost-opening-a-docked-panel-fetches-git-statistics ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))) visible refreshes)
     (dlet ((features (cons 'tmux-control features)))
       (cl-letf (((symbol-function 'roost--activate-workspace) #'ignore)
                 ((symbol-function 'tmux-control-window-id) (lambda () nil))
                 ((symbol-function 'tmux-control-connect-or-switch) #'ignore)
                 ((symbol-function 'tmux-control-send-command) #'ignore)
                 ((symbol-function 'tmux-control-select-pane) #'ignore)
                 ((symbol-function 'roost--sync-side-windows) (lambda (&rest _) (setq visible t)))
                 ((symbol-function 'roost--task-panel-window) (lambda () (when visible (selected-window))))
                 ((symbol-function 'roost--refresh-host) (lambda (host quiet) (push (list host quiet) refreshes))))
         (roost--display-task task)
         (should (equal refreshes '(("dev" nil))))
         ;; Opening the agent counts as seeing it.
         (should (equal (roost--attention-status task) "idle"))
         (setq visible nil refreshes nil)
         (cl-letf (((symbol-function 'roost--sync-side-windows) #'ignore))
           (roost--display-task task))
         (should-not refreshes))))))

(ert-deftest roost-shell-shows-both-panes-without-toggling-existing-tiling-off ()
  (roost-test--isolated
   (let ((tiled nil) (tiles 0))
     (cl-letf (((symbol-function 'roost--act) (lambda (task _action _params cb) (funcall cb task)))
               ((symbol-function 'roost--display-task) #'ignore)
               ((symbol-function 'roost--focus-shell) #'ignore)
               ((symbol-function 'tmux-control-tiled-p) (lambda () tiled))
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
                     ((symbol-function 'tmux-control-tiled-p) (lambda () t))
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
                 (setq-local roost-test--tmux `(:host "dev" :socket "main" :pane ,(cdr entry)))))
             (set-window-buffer origin agent) (set-window-buffer target shell)
             (roost-test--with-tmux-buffers
              (cl-letf (((symbol-function 'tmux-control-query) (lambda (_command cb) (funcall cb "@9")))
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
                (funcall callback) (should (eq (selected-window) origin)))))
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

(defun roost-test--wait-for (predicate)
  "Accept process output until PREDICATE returns non-nil, for up to 8 seconds."
  (let ((deadline (+ (float-time) 8)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil .05))))

(ert-deftest roost-large-requests-never-wait-for-the-host ()
  ;; A request larger than a pipe holds, such as the helper, waited with
  ;; Emacs frozen until ssh connected or gave up: ten seconds for a host
  ;; that was down.  The error then blamed a closed pipe rather than ssh.
  (roost-test--isolated
   (let ((large (make-string 200000 ?x))
         (inputs (directory-files temporary-file-directory nil "\\`roost-input-")))
     (dolist (case `((,large 2) ("{}" 2) ("{}" 0)))
       (let ((start (float-time)) failure)
         (roost--run nil (format "import sys,time; time.sleep(%d); sys.stderr.write('ssh: connect to host dev port 22: Operation timed out'); sys.exit(255)"
                                 (cadr case))
                     (car case) #'ignore (lambda (err) (setq failure err)))
         (should (< (- (float-time) start) 1))
         (roost-test--wait-for (lambda () failure))
         (should (equal failure "ssh: connect to host dev port 22: Operation timed out"))))
     (let (result)
       (roost--run nil "import sys,json; data=sys.stdin.read(); print(json.dumps({'ok': True, 'result': [len(data), data[:3]]}))"
                   (concat "é" large) (lambda (value) (setq result value)) #'ignore)
       (roost-test--wait-for (lambda () result))
       (should (equal result '(200001 "éxx"))))
     (should-not roost--requests)
     (should (equal (directory-files temporary-file-directory nil "\\`roost-input-") inputs)))))

(ert-deftest roost-a-request-that-slept-with-this-computer-gets-its-time-again ()
  ;; A request in flight when a laptop slept, or between Power Nap wakes,
  ;; failed the moment it woke, with "No reply after 60s".
  (let* ((roost-request-timeout 0.5) (offset 0) (timeouts 0)
         (real (symbol-function 'float-time))
         (process (make-process :name "roost-test-request" :command '("sleep" "30") :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'float-time) (lambda (&rest args) (+ offset (apply real args)))))
          (roost--expire-request process (lambda () (cl-incf timeouts)))
          ;; The clock jumps an hour, as across a sleep, before the timer runs:
          ;; the request gets its time again.
          (setq offset 3600)
          (let ((first (process-get process 'roost-timer)))
            (roost-test--wait-for (lambda () (not (eq (process-get process 'roost-timer) first)))))
          (should (process-live-p process))
          (should (= timeouts 0))
          ;; Awake, its time runs out as usual.
          (roost-test--wait-for (lambda () (not (process-live-p process))))
          (should (= timeouts 1)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest roost-a-removed-helper-is-installed-again ()
  ;; A task launched by another Emacs prunes helper copies over a week old.
  ;; Requests then failed, until a failed poll happened to reinstall it.
  (roost-test--isolated
   (let* ((root (make-temp-file "roost-rpc" t)) (roost-state-directory root) (results 0) failure)
     (unwind-protect
         (progn
           (dotimes (round 2)
             (dolist (helper (directory-files root t "\\`remote-.*\\.py\\'")) (delete-file helper))
             (roost--request nil "list" nil (lambda (_) (cl-incf results))
                              (lambda (err) (setq failure err)))
             (roost-test--wait-for (lambda () (or failure (> results round)))))
           (should-not failure)
           (should (= results 2))
           (should (= (length (directory-files root nil "\\`remote-.*\\.py\\'")) 1)))
       (delete-directory root t)))))

(ert-deftest roost-an-unreachable-host-keeps-its-helper ()
  ;; Each poll of a host that was down sent the whole helper again.
  (roost-test--isolated
   (let* ((roost-state-directory "~/state") (filename (car (roost--helper))) codes failure
          (fail-with nil))
     (puthash (list "dev" "~/state") filename roost--installed)
     (cl-letf (((symbol-function 'roost--run)
                (lambda (_host code _input success fail)
                  (push code codes)
                  (if (and fail-with (string-match-p "runpy" code))
                      (funcall fail (pop fail-with))
                    (funcall success nil)))))
       (setq fail-with (list "ssh: connect to host dev port 22: Operation timed out"))
       (roost--request "dev" "list" nil #'ignore (lambda (err) (setq failure err)))
       (should (= (length codes) 1))
       (should (equal failure "ssh: connect to host dev port 22: Operation timed out"))
       (should (equal (gethash (list "dev" "~/state") roost--installed) filename))
       ;; Python could not find the helper: install it and ask again.
       (setq codes nil failure nil
             fail-with (list (format "Traceback (most recent call last):\nFileNotFoundError: [Errno 2] No such file or directory: '/home/user/state/%s'" filename)))
       (roost--request "dev" "list" nil #'ignore (lambda (err) (setq failure err)))
       (should-not failure)
       (should (equal (mapcar (lambda (code) (if (string-match-p "runpy" code) 'invoke 'install))
                              (reverse codes))
                      '(invoke install invoke)))))))

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

(ert-deftest roost-agent-activity-fetches-its-git-statistics ()
  (roost-test--isolated
   (let ((roost-hosts '("dev")) calls)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action params success _failure)
                  (push (cons (alist-get 'full params) success) calls))))
       (roost--cache-task "dev" (roost-test--task nil "running"))
       ;; An unchanged status needs nothing more.
       (roost-refresh t)
       (funcall (cdar calls) (list (roost-test--task nil "running")))
       (should (= (length calls) 1))
       ;; A finished agent's task is measured for its changes.
       (roost-refresh t)
       (funcall (cdar calls) (list (roost-test--task nil "ready")))
       (should (= (length calls) 3))
       (should (equal (caar calls) ["0123456789abcdef"]))
       ;; So is one that reported again without changing status.
       (funcall (cdar calls) (list (roost-test--task nil "ready")))
       (roost-refresh t)
       (funcall (cdar calls) (list (append '((updatedAt . "2026-10-03T20:01:00+00:00"))
                                           (roost-test--task nil "ready"))))
       (should (= (length calls) 5))
       (should (equal (caar calls) ["0123456789abcdef"]))))))

(ert-deftest roost-a-moved-git-stamp-fetches-git-statistics ()
  ;; A commit made in the task's shell is no agent event.
  (roost-test--isolated
   (let ((roost-hosts '("dev")) calls)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action params success _failure)
                  (push (cons (alist-get 'full params) success) calls))))
       (roost--cache-task "dev" (cons '(gitStamp . "1 2 3") (roost-test--task nil "ready")))
       (roost-refresh t)
       (funcall (cdar calls) (list (cons '(gitStamp . "1 2 3") (roost-test--task nil "ready"))))
       (should (= (length calls) 1))
       ;; An inspection, which has no stamp, keeps the last one.
       (roost--cache-task "dev" (roost-test--task nil "ready"))
       (roost-refresh t)
       (funcall (cdar calls) (list (cons '(gitStamp . "1 2 3") (roost-test--task nil "ready"))))
       (should (= (length calls) 2))
       (roost-refresh t)
       (funcall (cdar calls) (list (cons '(gitStamp . "1 4 3") (roost-test--task nil "ready"))))
       (should (= (length calls) 4))
       (should (equal (caar calls) ["0123456789abcdef"]))))))

(ert-deftest roost-saving-a-file-in-a-worktree-measures-its-task ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))) refreshes)
     (cl-letf (((symbol-function 'roost--refresh-host)
                (lambda (host quiet &optional ids) (push (list host quiet ids) refreshes))))
       (let ((buffer-file-name "/ssh:dev:/home/user/work/fix auth/app.py"))
         (roost--file-saved))
       (let ((buffer-file-name "/ssh:dev:/home/user/elsewhere/app.py"))
         (roost--file-saved))
       (should (equal refreshes `(("dev" nil (,(roost--field task 'id))))))
       ;; An error would stop the hooks after this one; it only reports itself,
       ;; unless you are debugging (as ERT does in Emacs 29).
       (cl-letf (((symbol-function 'roost--task-in-directory)
                  (lambda (&rest _) (error "Not a Tramp file name"))))
         (let ((buffer-file-name "/ftp:host:/notes.txt")
               (debug-on-error nil))
           (should-not (roost--file-saved)))))
     (let ((after-save-hook nil) (global-mode-string nil) (roost-watch-mode nil))
       (unwind-protect
           (progn (roost-watch-mode 1)
                  (should (memq #'roost--file-saved after-save-hook)))
         (roost-watch-mode -1))
       (should-not (memq #'roost--file-saved after-save-hook))))))

(ert-deftest roost-magit-refreshes-measure-their-task ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))) refreshes)
     (cl-letf (((symbol-function 'roost--refresh-host)
                (lambda (host quiet &optional ids) (push (list host quiet ids) refreshes))))
       (let ((default-directory "/ssh:dev:/home/user/work/fix auth/"))
         (roost--magit-refreshed))
       (let ((default-directory "/ssh:dev:/home/user/elsewhere/"))
         (roost--magit-refreshed))
       (should (equal refreshes `(("dev" nil (,(roost--field task 'id))))))))))

(ert-deftest roost-mode-line-waiting-is-there-for-custom-mode-lines ()
  (roost-test--isolated
   (roost--cache-task "dev" (roost-test--task nil "permission"))
   (let ((roost-watch-mode nil))
     (should-not (roost-mode-line-waiting)))
   (let ((roost-watch-mode t))
     (should (equal (substring-no-properties (roost-mode-line-waiting)) " Roost:1 ")))))

(ert-deftest roost-a-seen-ready-agent-stops-counting-as-waiting ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "ready")))
         (roost-mode-line-count t))
     (should (equal (roost--attention-status task) "ready"))
     (should (string-match-p "Roost:1" (roost--mode-line-count)))
     (roost--mark-seen task)
     (should (equal (roost--attention-status task) "idle"))
     (should-not (roost--mode-line-count))
     (should-error (roost-next-waiting) :type 'user-error)
     ;; A new reply makes it wait again.
     (setq task (roost--cache-task "dev" (append '((updatedAt . "2026-10-03T20:05:00+00:00"))
                                                 (roost-test--task nil "ready"))))
     (should (equal (roost--attention-status task) "ready"))
     ;; Seeing a task that is working changes nothing until it is ready.
     (roost--mark-seen (roost--cache-task "dev" (roost-test--task nil "running")))
     (should (equal (roost--attention-status (roost--cache-task "dev" (roost-test--task nil "running")))
                    "running")))))

(ert-deftest roost-a-failed-or-crashed-agent-waits-until-you-have-seen-it ()
  ;; A usage limit or a crash notified you, then dropped out of `n' and the count.
  (roost-test--isolated
   (let ((roost-mode-line-count t) recorded opened)
     (cl-letf (((symbol-function 'roost--record-seen)
                (lambda (task updated) (push (list (roost--field task 'id) updated) recorded)))
               ((symbol-function 'roost-open-task) (lambda (task) (push (roost--field task 'id) opened))))
       (dolist (status '("failed" "crashed" "exited"))
         (clrhash roost--tasks)
         (clrhash roost--seen)
         (setq recorded nil)
         (let ((task (roost--cache-task "dev" (roost-test--task nil status))))
           (should (roost--waiting-p task))
           (should (string-match-p "Roost:1" (roost--mode-line-count)))
           ;; Counted in the colour of its row.
           (should (eq (get-text-property 1 'face (roost--mode-line-count))
                       (if (equal status "exited") 'roost-status-ready 'roost-status-failed)))
           (roost-next-waiting)
           (should (equal (car opened) "0123456789abcdef"))
           (roost--mark-seen task)
           (roost--mark-seen task)
           ;; Recorded on its host, once.
           (should (equal recorded '(("0123456789abcdef" "2026-10-03T20:00:00+00:00"))))
           (should-not (roost--waiting-p task))
           (should-not (roost--mode-line-count))
           ;; Still shown as what it is.
           (should (equal (roost--attention-status task) status))))
       ;; Stopped by you, it never waits.
       (should-not (roost--waiting-p (roost--cache-task "dev" (roost-test--task "1111111111111111" "stopped"))))
       ;; Watching an agent at work sends its host nothing on each event.
       (setq recorded nil)
       (dolist (minute '("01" "02" "03"))
         (roost--mark-seen (roost--cache-task "dev" (append `((updatedAt . ,(format "2026-10-03T20:%s:00+00:00" minute)))
                                                            (roost-test--task "2222222222222222" "running")))))
       (should-not recorded)))))

(ert-deftest roost-an-agent-seen-in-another-emacs-is-seen-here ()
  ;; The host keeps what you saw, so another machine, or the next session, agrees.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((seen . "2026-10-03T20:00:00+00:00"))
                                                (roost-test--task nil "ready")))))
     (should (equal (roost--attention-status task) "idle"))
     (should-not (roost--waiting-p task))
     ;; Its next reply waits again.
     (setq task (roost--cache-task "dev" (append '((seen . "2026-10-03T20:00:00+00:00")
                                                   (updatedAt . "2026-10-03T20:05:00+00:00"))
                                                 (roost-test--task nil "ready"))))
     (should (roost--waiting-p task)))))

(ert-deftest roost-watching-slows-down-while-emacs-is-not-in-front ()
  (roost-test--isolated
   (let ((refreshes 0) (focused nil) (now 1000.0) (roost--last-watch 0))
     (cl-letf (((symbol-function 'roost-refresh) (lambda (&rest _) (cl-incf refreshes)))
               ((symbol-function 'frame-focus-state) (lambda (&rest _) focused))
               ((symbol-function 'float-time) (lambda (&rest _) now)))
       (roost--watch-tick)
       (should (= refreshes 1))
       ;; Three seconds later, with no frame in front: not yet.
       (setq now 1003.0)
       (roost--watch-tick)
       (should (= refreshes 1))
       (setq now 1015.0)
       (roost--watch-tick)
       (should (= refreshes 2))
       ;; In front again: every tick.
       (setq focused t now 1018.0)
       (roost--watch-tick)
       (should (= refreshes 3))))))

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
     ;; A redraw keeps point on the same task, or project heading.
     (roost--render-dashboard)
     (should (equal (roost--field (roost--task-at-point) 'id) "3333333333333333"))
     (goto-char (point-min))
     (search-forward "local · site")
     (roost--render-dashboard)
     (should (looking-at-p "local · site")))
   ;; A quiet poll omits Git fields; the last full refresh's remain.
   (roost--apply-snapshot "dev" (list (append '((repo . "/home/user/ledger")) (roost-test--task "1111111111111111"))
                                      (append '((repo . "/home/user/ledger")) (roost-test--task "2222222222222222"))))
   (should (equal (roost--changes (gethash '("dev" "1111111111111111") roost--tasks))
                  "2 files +10 −3 · uncommitted · 1 ahead · 4 behind"))
   (should (equal (roost--changes '((diff . "1 file changed, 1 insertion(+)"))) "1 file +1 −0"))
   ;; Files Git does not track yet are counted from the list of changed files.
   (let ((new '((path . "now.txt") (untracked . t))))
     (should (equal (roost--changes `((diff . "") (dirty . t) (files ,new)))
                    "1 new file · uncommitted"))
     (should (equal (roost--changes `((diff . "1 file changed, 1 insertion(+)") (dirty . t)
                                      (files ((path . "a") (added . 1) (deleted . 0)) ,new ,new)))
                    "1 file +1 −0 · 2 new · uncommitted")))))

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

(ert-deftest roost-unreachable-hosts-are-named-rather-than-taken-as-empty ()
  (roost-test--isolated
   (let ((roost-hosts '(nil "dev" "lab")))
     (roost--cache-task "lab" (roost-test--task))
     (puthash "dev" "ssh: connect to host dev port 22: Host is down" roost--errors)
     (puthash "lab" "ssh: connect to host lab port 22: Host is down" roost--errors)
     (with-temp-buffer
       (roost-sidebar-list-mode)
       (roost--render-sidebar)
       ;; dev's tasks are unknown; lab's last known tasks are still listed.
       (should (string-match-p "^dev unreachable$" (buffer-string)))
       (should-not (string-match-p "^lab unreachable" (buffer-string))))
     (with-temp-buffer
       (roost-dashboard-mode)
       (roost--render-dashboard)
       (should (string-match-p "dev is unreachable, so its tasks are unknown: ssh: connect"
                               (buffer-string)))))))

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
                 (should (string-match-p "Finish   Pull request P    Merge and retire m    Retire or discard x    Forget X" text))
                 (should (string-match-p "Branch       codex/roost/fix-auth-123456, from main, merges into main" text))
                 (should (string-match-p "Worktree     ~/work/fix auth" text))
                 ;; Line counts keep their colors inside the indented section.
                 (goto-char (point-min))
                 (search-forward "+2")
                 (should (memq 'roost-diff-added (ensure-list (get-text-property (1- (point)) 'face))))
                 (should (string-match-p "Conversation abc-123" text))
                 (should-not display-line-numbers))
             (kill-buffer))))))))

(ert-deftest roost-merging-measures-the-other-tasks-again ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))) refreshes)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
               ((symbol-function 'roost--request)
                (lambda (_host _action _params success &optional _failure)
                  (funcall success (append '((status . "retired")) (roost-test--task)))))
               ((symbol-function 'roost--refresh-host)
                (lambda (host quiet &optional _ids) (push (list host quiet) refreshes))))
       (let ((dired (generate-new-buffer " *roost-test-dired*"))
             (notes (generate-new-buffer " *roost-test-notes*")))
         (with-current-buffer dired
           (dired-mode)
           (setq default-directory "/ssh:dev:/home/user/work/fix auth/"))
         (with-current-buffer notes
           (setq default-directory "/ssh:dev:/home/user/work/fix auth/"))
         (unwind-protect
             (progn
               (roost-merge-retire task)
               (should-not (roost-tasks))
               (should (equal refreshes '(("dev" nil))))
               ;; Views of the removed worktree go; other buffers stay.
               (should-not (buffer-live-p dired))
               (should (buffer-live-p notes)))
           (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
                 (list dired notes))))))))

(ert-deftest roost-forget-stops-a-running-agent-first ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "ready"))) actions)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (string-prefix-p "Stop " prompt)))
               ((symbol-function 'roost--request)
                (lambda (_host action _params success &optional _failure)
                  (push action actions)
                  (funcall success (append `((status . ,(if (equal action "stop") "stopped" "forgotten")))
                                           (roost-test--task))))))
       (roost-forget task)
       (should (equal (reverse actions) '("stop" "forget")))
       (should-not (roost-tasks))))))

(ert-deftest roost-forget-removes-the-task-and-reports-what-remains ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "stopped"))) messages)
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
         (roost-next-waiting) (should (equal opened "stuck"))
         ;; From the dashboard, the blocked task you last opened comes first.
         (with-temp-buffer
           (roost-dashboard-mode)
           (roost-next-waiting) (should (equal opened "stuck"))))))))

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
      (cl-letf (((symbol-function 'roost--read-task) (lambda (_) (setq asked t) task))
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
     (should (equal (roost--pr-initial-text task '("One" "Two" "Three"))
                    "One\n\nfix authentication\n\n- Two\n- Three\n"))
     (should (equal (roost--pr-initial-text task nil) "Fix auth flow\n\nfix authentication\n"))
     (should (equal (roost--pr-initial-text task '("Fix the login\n\nTokens expired early."))
                    "Fix the login\n\nTokens expired early.\n"))
     (should (equal (roost--pr-initial-text task '("Fix the login\n\nTokens expired early."
                                                   "Address review"))
                    "Fix the login\n\nTokens expired early.\n\n- Address review\n"))
     (setf (alist-get 'task task) "fix-auth_flow")
     (should (equal (roost--pr-initial-text task '("One" "Two")) "One\n\n- Two\n"))
     (should (equal (roost--pr-initial-text task nil) "Fix auth flow\n\n")))))

(ert-deftest roost-pr-commit-messages-drop-trailers ()
  (should (equal (roost--without-trailers "Fix\n\nBody text.\n\nCo-Authored-By: A <a@b>\n")
                 "Fix\n\nBody text."))
  (should (equal (roost--without-trailers "Fix\n\nNote: this stays\nbecause it wraps.")
                 "Fix\n\nNote: this stays\nbecause it wraps."))
  (should (equal (roost--without-trailers "Fix the login\n") "Fix the login"))
  (should (equal (roost--without-trailers "fix: handle nil\n\nSigned-off-by: A <a@b>")
                 "fix: handle nil"))
  (should (equal (roost--without-trailers "feat: add x\n\nNote: kept.") "feat: add x\n\nNote: kept.")))

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

(ert-deftest roost-pr-commits-leave-out-updates-from-the-integration-branch ()
  (let* ((dir (make-temp-file "roost-pr" t))
         (default-directory (file-name-as-directory dir))
         (git (lambda (&rest args)
                (apply #'call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@t"
                       args))))
    (funcall git "init" "-q" "-b" "main")
    (funcall git "commit" "-q" "--allow-empty" "-m" "start")
    (let ((base (string-trim (shell-command-to-string "git rev-parse HEAD"))))
      (funcall git "checkout" "-q" "-b" "task")
      (funcall git "commit" "-q" "--allow-empty" "-m" "task work")
      (funcall git "checkout" "-q" "main")
      (funcall git "commit" "-q" "--allow-empty" "-m" "main moved")
      (funcall git "checkout" "-q" "task")
      (funcall git "merge" "-q" "--no-edit" "main")
      (let ((task `((worktree . ,dir) (baseCommit . ,base) (integrationBranch . "main"))))
        (should (equal (roost--fork-point task)
                       (string-trim (shell-command-to-string "git rev-parse main"))))
        (should (equal (roost--pr-commits task) '("task work"))))
      (let ((task `((worktree . ,dir) (baseCommit . ,base) (integrationBranch . "gone"))))
        (should (equal (roost--fork-point task) base))))))

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

(ert-deftest roost-pr-pushes-then-opens-the-existing-one-in-the-browser ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--pr-task))) opened sent messages)
     (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url)))
               ((symbol-function 'roost--redraw) #'ignore)
               ((symbol-function 'message)
                (lambda (format &rest args) (push (apply #'format-message format args) messages)))
               ((symbol-function 'roost--request)
                (lambda (_host action _params success &rest _)
                  (setq sent action)
                  (funcall success (cons '(pushed . 2) (roost-test--pr-task))))))
       (roost-pr task)
       (should (equal sent "pr"))
       (should (member "Roost: Pushed 2 commits to #12" messages))
       (should (equal opened "https://github.com/o/r/pull/12"))
       (should-not (alist-get 'pushed (gethash '("dev" "0123456789abcdef") roost--tasks)))))))

(ert-deftest roost-pr-reports-an-up-to-date-pull-request ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--pr-task))) opened messages)
     (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url)))
               ((symbol-function 'roost--redraw) #'ignore)
               ((symbol-function 'message)
                (lambda (format &rest args) (push (apply #'format-message format args) messages)))
               ((symbol-function 'roost--request)
                (lambda (_host _action _params success &rest _)
                  (funcall success (cons '(pushed . 0) (roost-test--pr-task))))))
       (roost-pr task)
       (should (member "Roost: #12 is up to date" messages))
       (should (equal opened "https://github.com/o/r/pull/12"))))))

(ert-deftest roost-pr-prefix-opens-the-existing-one-without-pushing ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--pr-task))) opened)
     (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url)))
               ((symbol-function 'roost--request)
                (lambda (&rest _) (ert-fail "should not push"))))
       (roost-pr task t)
       (should (equal opened "https://github.com/o/r/pull/12"))))))

(ert-deftest roost-pr-does-not-push-to-a-merged-pull-request ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((prStatus (state . "MERGED")))
                                                (roost-test--pr-task))))
         opened)
     (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url)))
               ((symbol-function 'roost--request)
                (lambda (&rest _) (ert-fail "should not push"))))
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
                   '("#12 merged" . roost-pr-merged)))
    (should (equal (funcall marker '(prStatus . ((state . "CLOSED")))) '("#12 closed" . roost-pr-closed)))
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

(ert-deftest roost-doctor-requires-tmux-control-public-api ()
  (dolist (case '((nil nil "Install tmux-control") ("0.6.0" nil "0.7.0 or newer")
                  ("installed" nil "0.7.0 or newer") ("0.7.0" t nil) ("0.10.1" t nil)))
    (cl-letf (((symbol-function 'roost--library-version)
               (lambda (library) (and (equal library "tmux-control") (car case)))))
      (let ((check (assoc "tmux-control" (roost--doctor-local-checks))))
        (should (eq (and (nth 1 check) t) (nth 1 case)))
        (should (equal (nth 2 check) (car case)))
        (when (nth 2 case) (should (string-match-p (nth 2 case) (nth 3 check))))))))

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

(ert-deftest roost-every-roost-buffer-reaches-the-other-tasks ()
  ;; `n' in a task's panel beeped, though the menu lists it everywhere.
  (dolist (map (list roost-dashboard-mode-map roost-task-info-mode-map roost-sidebar-list-mode-map))
    (should (eq (lookup-key map "n") #'roost-next-waiting))
    (should (eq (lookup-key map "c") #'roost-new-task))
    (should (eq (lookup-key map "b") #'roost-sidebar-mode))
    (should (eq (lookup-key map "h") #'roost-dispatch)))
  (should (eq (lookup-key roost-task-info-mode-map "S") #'roost-status))
  (should (eq (lookup-key roost-sidebar-list-mode-map "S") #'roost-status)))

(ert-deftest roost-draft-and-dashboard-take-the-window-you-are-in ()
  ;; A split squeezed the agent's terminal beside them; quitting gives the
  ;; window back.
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let ((main (selected-window))
           (terminal (get-buffer-create " *roost-test terminal*")))
       (unwind-protect
           (progn
             (set-window-buffer main terminal)
             (cl-letf (((symbol-function 'roost-refresh) #'ignore)
                       ((symbol-function 'roost-watch-mode) #'ignore))
               (roost-status))
             (should (equal (buffer-name (window-buffer main)) "*roost*"))
             (should (= (length (window-list)) 1))
             (quit-window)
             (should (eq (window-buffer main) terminal))
             (roost-new-task)
             (should (eq (window-buffer main) (get-buffer roost--compose-buffer)))
             (should (= (length (window-list)) 1)))
         (kill-buffer terminal)
         (when (get-buffer roost--compose-buffer)
           (kill-buffer roost--compose-buffer)))))))

(ert-deftest roost-an-unreachable-host-is-reported-once-per-outage ()
  ;; ssh alternated "Operation timed out" and "Host is down" for a host
  ;; asleep, and each change printed again.
  (roost-test--isolated
   (let ((roost-hosts '("dev")) (messages '()) failure success)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params ok fail) (setq success ok failure fail)))
               ((symbol-function 'message)
                (lambda (format &rest args) (push (apply #'format format args) messages))))
       (dolist (err '("mux_client_request_session: read from master failed: Broken pipe
ssh: connect to host dev port 22: Operation timed out"
                      "ssh: connect to host dev port 22: Host is down"
                      "ssh: connect to host dev port 22: Operation timed out"))
         (clrhash roost--refreshing)
         (roost--refresh-host "dev" t)
         (funcall failure err))
       (should (= (length messages) 1))
       ;; One line, the one that says what failed; the sidebar has the rest.
       (should (equal (car messages) "Roost dev: ssh: connect to host dev port 22: Operation timed out (M-x roost-doctor checks this host)"))
       ;; Back, then down again: a new outage.
       (clrhash roost--refreshing)
       (roost--refresh-host "dev" t)
       (funcall success nil)
       (clrhash roost--refreshing)
       (roost--refresh-host "dev" t)
       (funcall failure "ssh: connect to host dev port 22: Host is down")
       (should (= (length messages) 2))))))

(ert-deftest roost-merging-uncommitted-work-offers-magit-instead ()
  ;; The host refuses a dirty worktree, so asking to merge first only led
  ;; to that refusal.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((dirty . t)) (roost-test--task))))
         actions reviewed questions)
     (cl-letf (((symbol-function 'roost--act) (lambda (_task action &rest _) (push action actions)))
               ((symbol-function 'roost-review) (lambda (task) (setq reviewed task)))
               ((symbol-function 'yes-or-no-p) (lambda (q) (push q questions) t))
               ((symbol-function 'y-or-n-p) (lambda (q) (push q questions) t)))
       (roost-merge-retire task)
       (should-not actions)
       (should (eq reviewed task))
       (should (string-match-p "uncommitted" (car questions)))
       ;; Committed and clean: merge as before.
       (roost-merge-retire (roost--cache-task "dev" (roost-test--task "fedcba9876543210")))
       (should (equal actions '("merge")))))))

(ert-deftest roost-rows-light-up-alone-and-keep-their-task-at-the-line-end ()
  ;; With the newline in the highlighted text, hovering a row lit up the
  ;; next; taking the newline out of the row lost the task there, so a
  ;; redraw moved point from a row's end to the first task.
  (roost-test--isolated
   (dolist (spec '(("1111111111111111" "alpha" "1") ("2222222222222222" "beta" "2")))
     (roost--cache-task "dev" (append `((repo . "/home/user/p") (startedAt . ,(nth 2 spec)) (name . ,(nth 1 spec)))
                                      (roost-test--task (car spec) "ready"))))
   (dolist (mode '(roost-dashboard-mode roost-sidebar-list-mode))
     (with-temp-buffer
       (funcall mode)
       (let ((render (if (eq mode 'roost-dashboard-mode) #'roost--render-dashboard #'roost--render-sidebar)))
         (funcall render)
         (goto-char (point-min))
         (search-forward "beta")
         (end-of-line)
         (should (eq (get-text-property (1- (point)) 'mouse-face) 'highlight))
         (should-not (get-text-property (point) 'mouse-face))
         (should (eq (get-text-property (point) 'keymap) roost--dashboard-row-map))
         (funcall render)
         (should (equal (roost--field (roost--dashboard-task) 'name) "beta")))))))

(ert-deftest roost-ending-a-task-closes-its-own-terminal-first ()
  ;; Its session ends with it; the terminal would report a lost connection.
  (roost-test--isolated
   (let* ((own (roost--cache-task "dev" (append '((session . "roost-p-012345"))
                                                (roost-test--task "0123456789abcdef" "ready"))))
          (shared (roost--cache-task "dev" (append '((session . "roost-p-3f2a"))
                                                   (roost-test--task "fedcba9876543210" "ready"))))
          (terminals (mapcar (lambda (session)
                               (with-current-buffer (generate-new-buffer " *terminal*")
                                 (setq-local roost-test--tmux `(:host "dev" :socket "main" :session ,session))
                                 (make-pipe-process :name "roost-test-terminal" :buffer (current-buffer)
                                                    :noquery t)
                                 (current-buffer)))
                             '("roost-p-012345" "roost-p-3f2a")))
          ;; A scrollback view, more recent than the terminal, holds no connection.
          (scrollback (with-current-buffer (generate-new-buffer " *scrollback*")
                        (setq-local roost-test--tmux '(:host "dev" :socket "main" :session "roost-p-012345"))
                        (mapc #'bury-buffer terminals)
                        (current-buffer)))
          disconnected actions)
     (unwind-protect
         (roost-test--with-tmux-buffers
          (cl-letf (((symbol-function 'tmux-control-buffer-session)
                     (lambda () (plist-get roost-test--tmux :session)))
                    ((symbol-function 'tmux-control-disconnect)
                     (lambda () (when (get-buffer-process (current-buffer))
                                  (push (plist-get roost-test--tmux :session) disconnected))))
                    ((symbol-function 'roost--request)
                     (lambda (_host action &rest _) (push (cons action disconnected) actions))))
            (roost--act own "send")
            (should-not disconnected)
            (roost--act own "stop")
            (should (equal disconnected '("roost-p-012345")))
            ;; Disconnected before the host was asked.
            (should (equal (car actions) '("stop" "roost-p-012345")))
            (setq disconnected nil)
            (roost--act shared "retire")
            (should-not disconnected)
            ;; The host refuses to resume an agent still running.
            (roost--act (roost--cache-task "dev" (append '((live . t)) own)) "resume")
            (should-not disconnected)
            (roost--act (roost--cache-task "dev" (append '((live)) own)) "resume")
            (should (equal disconnected '("roost-p-012345")))))
       (mapc #'kill-buffer (cons scrollback terminals))))))

(ert-deftest roost-a-closed-terminal-goes-or-comes-back-with-the-hosts-answer ()
  ;; Once the session has ended, its blank terminal goes.  When the host
  ;; refuses, as it does to retire unmerged work, the agent runs on and
  ;; the terminal you were watching reconnects.
  (roost-test--isolated
   (let* ((task (roost--cache-task "dev" (append '((session . "roost-p-012345") (live . t))
                                                 (roost-test--task "0123456789abcdef" "ready"))))
          (make (lambda ()
                  (with-current-buffer (generate-new-buffer " *terminal*")
                    (setq-local roost-test--tmux '(:host "dev" :socket "main" :session "roost-p-012345"))
                    (current-buffer))))
          (answer nil) window-gone reconnected refusal)
     (roost-test--with-tmux-buffers
      (cl-letf (((symbol-function 'tmux-control-buffer-session)
                 (lambda () (plist-get roost-test--tmux :session)))
                ((symbol-function 'tmux-control-disconnect) #'ignore)
                ((symbol-function 'tmux-control-reconnect)
                 (lambda () (push (current-buffer) reconnected)))
                ((symbol-function 'roost--request)
                 (lambda (_host action _parameters success failure)
                   (if (and (stringp answer) (or (not (equal action "inspect")) window-gone))
                       (funcall failure answer)
                     (funcall success task)))))
        (let ((terminal (funcall make)))
          (save-window-excursion
            (set-window-buffer (selected-window) terminal)
            (roost--act task "stop"))
          (should-not (buffer-live-p terminal)))
        (let ((terminal (funcall make)))
          (unwind-protect
              (save-window-excursion
                (set-window-buffer (selected-window) terminal)
                (setq answer "Task branch is not merged")
                (roost--act task "retire" nil nil (lambda (err) (setq refusal err)))
                (should (equal refusal "Task branch is not merged"))
                (should (equal reconnected (list terminal)))
                (should (buffer-live-p terminal))
                ;; Reconnecting to an ended session would start an empty one.
                (setq window-gone t reconnected nil)
                (roost--act task "retire" nil nil #'ignore)
                (should-not reconnected))
            (kill-buffer terminal))))))))

(ert-deftest roost-the-sidebar-highlights-the-row-its-keys-act-on ()
  ;; It shows no cursor, so nothing said which task `s' would resume.
  (roost-test--isolated
   (dolist (spec '(("1111111111111111" "alpha" "1") ("2222222222222222" "beta" "2")))
     (roost--cache-task "dev" (append `((repo . "/home/user/p") (startedAt . ,(nth 2 spec)) (name . ,(nth 1 spec)))
                                      (roost-test--task (car spec) "ready"))))
   (let ((roost-workspace nil)          ; The frame names the task you are in.
         (sidebar (roost--sidebar-get-buffer))
         (row (lambda (name) (with-current-buffer roost--sidebar-buffer
                               (save-excursion (goto-char (point-min)) (search-forward name)
                                               (line-beginning-position))))))
     (unwind-protect
         (save-window-excursion
           ;; Entered at the top: the selection starts on the task you are in.
           (set-frame-parameter nil 'roost-task '("dev" "2222222222222222"))
           (set-window-buffer (selected-window) sidebar)
           (set-window-point (selected-window) 1)
           (roost--sidebar-entered)
           (with-current-buffer sidebar
             (should (= (overlay-start roost--sidebar-selection) (funcall row "beta")))
             (should (eq (overlay-get roost--sidebar-selection 'window) (selected-window)))
             ;; It follows point, and outlasts a redraw.
             (goto-char (funcall row "alpha"))
             (roost--sidebar-mark-selection)
             (roost--render-sidebar)
             (should (= (overlay-start roost--sidebar-selection) (funcall row "alpha")))
             ;; Once in, point can rest on a project's heading, for `c',
             ;; and stays there through a redraw.
             (goto-char (funcall row "dev · p"))
             (roost--sidebar-mark-selection)
             (roost--render-sidebar)
             (should (= (point) (funcall row "dev · p")))
             (should (= (overlay-start roost--sidebar-selection) (funcall row "dev · p"))))
           ;; So may a click that enters the sidebar there.
           (set-window-point (selected-window) (funcall row "dev · p"))
           (let ((last-input-event `(mouse-1 (,(selected-window) ,(funcall row "dev · p") (0 . 0) 0))))
             (roost--sidebar-entered))
           (should (= (window-point) (funcall row "dev · p")))
           ;; Elsewhere, the sidebar shows no selection.
           (set-window-buffer (selected-window) (get-buffer-create " *elsewhere*"))
           (roost--sidebar-mark-selection)
           (with-current-buffer sidebar
             (should-not (overlay-buffer roost--sidebar-selection))))
       (kill-buffer sidebar)
       (when (get-buffer " *elsewhere*") (kill-buffer " *elsewhere*"))))))

(ert-deftest roost-opening-a-task-whose-window-is-gone-offers-to-resume-it ()
  ;; After a crash, RET said only "resume the task".
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "crashed")))
         (reply "The agent's tmux window is gone; resume the task")
         (answer t) asked resumed messages)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params _success failure) (funcall failure reply)))
               ((symbol-function 'y-or-n-p) (lambda (question) (push question asked) answer))
               ((symbol-function 'roost-resume) (lambda (task) (push task resumed)))
               ((symbol-function 'message) (lambda (format &rest args) (push (apply #'format format args) messages))))
       (roost-open-task task)
       (should (equal asked '("fix auth's agent isn't running.  Resume its conversation? ")))
       (should (equal resumed (list task)))
       (setq answer nil)
       (roost-open-task task)
       (should (= (length resumed) 1))
       ;; Other failures are reported, not offered.
       (setq reply "ssh: connect to host dev port 22: Operation timed out" asked nil)
       (roost-open-task task)
       (should-not asked)
       (should (equal (car messages) "Roost dev: ssh: connect to host dev port 22: Operation timed out"))))))

(ert-deftest roost-task-sessions-stay-out-of-tmux-controls-activity-corner ()
  ;; The corner named every other task whose agent printed anything, and
  ;; clicking it showed that terminal without switching task.
  (roost-test--isolated
   (let* ((task (roost--cache-task "dev" (append '((session . "roost-p-012345"))
                                                 (roost-test--task "0123456789abcdef" "ready"))))
          (buffers
           (mapcar (lambda (spec)
                     (with-current-buffer (generate-new-buffer " *terminal*")
                       (setq-local roost-test--tmux (car spec))
                       (when (cdr spec)
                         (make-process :name "roost-test-connection" :buffer (current-buffer)
                                       :command '("sleep" "30") :noquery t))
                       (current-buffer)))
                   ;; The task's connection, a window buffer of it, another session.
                   '(((:host "dev" :socket "main" :session "roost-p-012345") . t)
                     ((:host "dev" :socket "main" :session "roost-p-012345"))
                     ((:host "dev" :socket "main" :session "notes") . t)))))
     (unwind-protect
         (roost-test--with-tmux-buffers
          (cl-letf (((symbol-function 'tmux-control-buffer-session)
                     (lambda () (plist-get roost-test--tmux :session))))
            (roost--quiet-session-activity task)
            (should (equal (mapcar (lambda (buffer)
                                     (local-variable-p 'tmux-control-session-activity buffer))
                                   buffers)
                           '(t nil nil)))
            (should-not (buffer-local-value 'tmux-control-session-activity (car buffers)))))
       (dolist (buffer buffers)
         (when (get-buffer-process buffer) (delete-process (get-buffer-process buffer)))
         (kill-buffer buffer))))))

;;;; Review notes

(defun roost-test--note (id task-id &rest fields)
  "A review note ID for the task TASK-ID on host dev, with FIELDS."
  (append `((id . ,id) (host . "dev") (task . ,task-id)) fields))

(ert-deftest roost-notes-quote-their-lines-for-the-agent ()
  (should (equal (roost--format-note '((file . "a.py") (line . 3) (end . 4)
                                       (quote "+one" " two") (text . "Why?")))
                 "a.py:3-4\n> +one\n>  two\nWhy?"))
  (should (equal (roost--format-note '((file . "a.py") (line . 7) (end . 7) (removed . t)
                                       (quote "-gone") (text . "Keep it")))
                 "a.py:7 (a removed line)\n> -gone\nKeep it"))
  (should (equal (roost--format-note '((file . "README.md") (text . "Mention the key")))
                 "README.md\nMention the key"))
  (let ((long (roost--format-note `((file . "b") (line . 1) (end . 10)
                                    (quote ,@(make-list 10 "+x")) (text . "t")))))
    (should (string-suffix-p "> …\nt" long))
    (should (= (cl-count ?> long) 9))))

(ert-deftest roost-notes-survive-a-restart ()
  (roost-test--isolated
   (let ((notes (list (roost-test--note "1" "t1" '(file . "a.py") '(line . 2) '(end . 3)
                                        '(removed . t) '(quote "-a" "-b") '(text . "x"))
                      '((id . "2") (task . "t2") (file . "b.py") (text . "whole")))))
     (setq roost--notes (copy-tree notes))
     (roost--save-notes)
     (setq roost--notes nil roost--notes-loaded nil)
     (should (equal (roost--notes) notes)))))

(ert-deftest roost-a-sent-draft-delivers-and-clears-its-notes ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let* ((task (roost--cache-task "dev" (roost-test--task)))
           (id (roost--field task 'id))
           sent)
      (setq roost--notes
            (list (roost-test--note "n1" id '(file . "a.py") '(line . 2) '(end . 2)
                                    '(quote "+x = 1") '(text . "Name it"))
                  (roost-test--note "n2" "another task" '(file . "b.py") '(text . "Not mine"))))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--refresh-host) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore)
                ((symbol-function 'roost--request)
                 (lambda (_host _action params success &rest _)
                   (setq sent params)
                   (funcall success (roost-test--task)))))
        (roost--send-draft task)
        (should (equal (buffer-string) "\n\na.py:2\n> +x = 1\nName it"))
        (should (= (point) (point-min)))
        ;; A note written while the draft is open joins it, once.
        (setq roost--notes (append roost--notes
                                   (list (roost-test--note "n3" id '(file . "c.py") '(text . "Also")))))
        (roost--send-draft task)
        (roost--send-draft task)
        (should (equal (buffer-string) "\n\na.py:2\n> +x = 1\nName it\n\nc.py\nAlso"))
        (goto-char (point-min))
        (insert "Please:")
        (roost-send-submit)
        (should (equal (alist-get 'text sent) "Please:\n\na.py:2\n> +x = 1\nName it\n\nc.py\nAlso"))
        (should (equal (mapcar (lambda (note) (alist-get 'id note)) roost--notes) '("n2")))
        (with-temp-buffer
          (insert-file-contents roost-notes-file)
          (should-not (string-match-p "n1\\|n3" (buffer-string)))))))))

(ert-deftest roost-notes-stay-until-a-draft-holding-them-is-sent ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let* ((task (roost--cache-task "dev" (roost-test--task))) sent)
      (setq roost--notes (list (roost-test--note "n1" (roost--field task 'id)
                                                 '(file . "a.py") '(text . "Why?"))))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--refresh-host) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore)
                ((symbol-function 'roost--request)
                 (lambda (_host _action params success &rest _)
                   (setq sent params)
                   (funcall success (roost-test--task)))))
        (roost--send-draft task)
        ;; Emptied by hand, the draft takes its notes back.
        (erase-buffer)
        (roost--send-draft task)
        (should (equal (buffer-string) "\n\na.py\nWhy?"))
        ;; A discarded draft leaves them.
        (kill-buffer)
        (should (= (length roost--notes) 1))
        (roost--send-draft task)
        (roost-send-submit)
        ;; Sent as written, without the blank lines left for an introduction.
        (should (equal (alist-get 'text sent) "a.py\nWhy?"))
        (should-not roost--notes))))))

(ert-deftest roost-send-region-adds-to-a-draft-already-begun ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let ((task (roost--cache-task "dev" (roost-test--task))))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--directory-host) (lambda (_) "dev")))
        (roost--send-draft task)
        (insert "Look at these:")
        (with-temp-buffer
          (setq buffer-file-name "/home/user/work/fix auth/src/a.py")
          (insert "x\n")
          (set-buffer-modified-p nil)
          (roost-send-region (point-min) (point-max)))
        (with-current-buffer "*roost send: fix auth*"
          (should (equal (buffer-string) "Look at these:\n\nsrc/a.py:1-1\n\nx\n"))))))))

(ert-deftest roost-tasks-with-one-name-keep-drafts-and-notes-of-their-own ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let* ((here (roost--cache-task "dev" (roost-test--task "a")))
           (there (roost--cache-task "other" (roost-test--task "b")))
           sent)
      (setq roost--notes (list (roost-test--note "1" "a" '(file . "x.py") '(text . "Here"))
                               '((id . "2") (host . "other") (task . "b") (file . "y.py")
                                 (text . "There"))))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--refresh-host) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore)
                ((symbol-function 'roost--request)
                 (lambda (host _action params success &rest _)
                   (setq sent (cons host params))
                   (funcall success (roost-test--task)))))
        (roost--send-draft here)
        (should (equal (buffer-name) "*roost send: fix auth on dev*"))
        (roost--send-draft there)
        (should (equal (buffer-name) "*roost send: fix auth on other*"))
        (should (equal (buffer-string) "\n\ny.py\nThere"))
        (roost-send-submit)
        (should (equal sent '("other" (id . "b") (text . "y.py\nThere"))))
        ;; The other task's draft and note are as they were.
        (should (equal (mapcar (lambda (note) (alist-get 'id note)) roost--notes) '("1")))
        (roost--send-draft here)
        (should (equal (buffer-string) "\n\nx.py\nHere")))))))

(ert-deftest roost-notes-go-with-their-task ()
  (roost-test--isolated
   (roost--cache-task "dev" (roost-test--task "a"))
   (roost--cache-task "dev" (roost-test--task "b"))
   (setq roost--notes (list (roost-test--note "1" "a" '(file . "x") '(text . "t"))
                            (roost-test--note "2" "b" '(file . "x") '(text . "t"))
                            '((id . "3") (host . "other") (task . "b") (file . "x") (text . "t"))))
   (should (equal (roost--notes-summary (gethash '("dev" "b") roost--tasks))
                  "1 review note for the agent; e sends it"))
   (roost--cache-task "dev" (roost-test--task "a" "retired"))
   (should (equal (mapcar (lambda (note) (alist-get 'id note)) roost--notes) '("2" "3")))
   ;; A task gone from its host's listing, as when retired elsewhere.
   (roost--apply-snapshot "dev" nil)
   (should (equal (mapcar (lambda (note) (alist-get 'id note)) roost--notes) '("3")))))

(ert-deftest roost-discarding-notes-asks-and-keeps-other-tasks-notes ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task "a"))) answer)
     (setq roost--notes (list (roost-test--note "1" "a" '(file . "x") '(text . "t"))
                              (roost-test--note "2" "b" '(file . "x") '(text . "t"))))
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) answer))
               ((symbol-function 'roost--redraw) #'ignore))
       (roost-discard-notes task)
       (should (= (length roost--notes) 2))
       (setq answer t)
       (roost-discard-notes task)
       (should (equal (mapcar (lambda (note) (alist-get 'id note)) roost--notes) '("2")))
       (should-error (roost-discard-notes task) :type 'user-error)))))

;;;; Review notes in Magit, on a real repository

(defmacro roost-test--with-magit-task (&rest body)
  "Run BODY with `task', a local task whose worktree `dir' is a Git repository.
Its a.txt has ten lines, committed.  Skipped without Magit."
  (declare (indent 0))
  `(progn
     (skip-unless (and (executable-find "git") (require 'magit nil t)))
     (roost-test--isolated
      (let* ((dir (file-name-as-directory (file-truename (make-temp-file "roost-magit" t))))
             (default-directory dir)
             (process-environment (append '("GIT_AUTHOR_NAME=Roost" "GIT_AUTHOR_EMAIL=r@example.com"
                                            "GIT_COMMITTER_NAME=Roost" "GIT_COMMITTER_EMAIL=r@example.com"
                                            "GIT_CONFIG_GLOBAL=/dev/null")
                                          process-environment))
             (task (roost--cache-task nil (append `((worktree . ,(directory-file-name dir))
                                                    (integrationBranch . "main")
                                                    (lastMessage . "Renamed the lines.\n\nAll tests pass."))
                                                  (roost-test--task)))))
        (ignore task)
        (unwind-protect
            (cl-letf (((symbol-function 'roost--redraw) #'ignore))
              (call-process "git" nil nil nil "init" "-q")
              (roost-test--write-lines "a.txt" (number-sequence 1 10))
              (call-process "git" nil nil nil "add" ".")
              (call-process "git" nil nil nil "commit" "-qm" "Start")
              (roost--magit-setup)
              ,@body)
          (dolist (buffer (buffer-list))
            (when (provided-mode-derived-p (buffer-local-value 'major-mode buffer) 'magit-mode)
              (kill-buffer buffer)))
          (roost--magit-teardown)
          (delete-directory dir t))))))

(defun roost-test--write-lines (file numbers &optional extra)
  "Write FILE with a line for each of NUMBERS, then EXTRA after line 4."
  (with-temp-file file
    (dolist (number numbers)
      (insert (format "line %d\n" number))
      (when (and extra (= number 4)) (insert extra)))))

(defun roost-test--goto-line-text (text)
  "Move to the start of the diff line whose text after its marker is TEXT."
  (goto-char (point-min))
  (re-search-forward (concat "^[-+ ]" (regexp-quote text) "$"))
  (beginning-of-line))

(defun roost-test--shown-notes ()
  "The notes shown in this buffer, as (TEXT-OF-LINE . NOTE-TEXT), in order."
  (seq-mapcat (lambda (overlay)
                (let ((line (buffer-substring-no-properties
                             (save-excursion (goto-char (overlay-start overlay))
                                             (line-beginning-position))
                             (overlay-start overlay))))
                  (mapcar (lambda (note) (cons line (alist-get 'text note)))
                          (overlay-get overlay 'roost-notes))))
              (sort (copy-sequence roost--note-overlays)
                    (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(ert-deftest roost-notes-are-written-on-diff-lines-in-magit ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (should roost-magit-mode)
      (let (answer)
        (cl-letf (((symbol-function 'read-string) (lambda (_prompt &optional initial) (or answer initial ""))))
          ;; An added line.
          (roost-test--goto-line-text "new line")
          (setq answer "Name it")
          (roost-note)
          ;; A context line and the added one, as a region.
          (roost-test--goto-line-text "line 4")
          (set-mark (point))
          (forward-line 2)
          (activate-mark)
          (setq answer "These two")
          (roost-note)
          (should-not (use-region-p))
          ;; The whole file, from its name.
          (goto-char (point-min))
          (re-search-forward "^modified +a.txt")
          (setq answer "Whole file")
          (roost-note)
          (should (equal (mapcar (lambda (note) (roost--format-note note)) roost--notes)
                         '("a.txt:5\n> +new line\nName it"
                           "a.txt:4-5\n>  line 4\n> +new line\nThese two"
                           "a.txt\nWhole file")))
          (should (equal (roost-test--shown-notes)
                         '(("modified   a.txt" . "Whole file")
                           ("+new line" . "Name it")
                           ("+new line" . "These two"))))
          ;; On a noted line, the note is edited; left empty, removed.
          (roost-test--goto-line-text "new line")
          (setq answer nil)
          (cl-letf (((symbol-function 'read-string) (lambda (_prompt &optional initial)
                                                      (should (equal initial "Name it"))
                                                      "")))
            (roost-note))
          (should (equal (mapcar (lambda (note) (alist-get 'text note)) roost--notes)
                         '("These two" "Whole file"))))))))

(ert-deftest roost-notes-follow-their-line-when-the-agent-edits-above-it ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Removed?")))
        ;; A removed line keeps the old version's numbers.
        (roost-test--write-lines "a.txt" (append '(1 2 3 4) (number-sequence 6 10)) "new line\n")
        (magit-refresh)
        (roost-test--goto-line-text "line 5")
        (roost-note)
        (should (equal (roost--format-note (car roost--notes))
                       "a.txt:5 (a removed line)\n> -line 5\nRemoved?")))
      ;; The agent adds two lines at the top: the note moves with its line.
      (roost-test--write-lines "a.txt" (append '(0 0 1 2 3 4) (number-sequence 6 10)) "new line\n")
      (magit-refresh)
      (should (equal (roost-test--shown-notes) '(("-line 5" . "Removed?")))))))

(ert-deftest roost-magit-status-names-the-task-and-shows-notes ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (setq roost--notes (list `((id . "1") (task . ,(roost--field task 'id)) (file . "a.txt")
                               (line . 5) (end . 5) (quote "+new line") (text . "Name it"))))
    (magit-status-setup-buffer dir)
    (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
      (should roost-magit-mode)
      ;; Without the agent's status, which would go stale before a refresh.
      (should (string-match-p "^Task: +fix auth, merges into main$" (buffer-string)))
      (goto-char (point-min))
      (re-search-forward "^Agent's latest reply  Renamed the lines\\.$")
      (should (eieio-oref (magit-current-section) 'hidden))
      (should (equal (roost-test--shown-notes) '(("+new line" . "Name it")))))
    ;; They can be turned off; notes still show.
    (let ((roost-magit-status-sections nil))
      (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
        (magit-refresh-buffer)
        (should-not (string-match-p "^Task:\\|^Agent's latest reply" (buffer-string)))
        (should (equal (roost-test--shown-notes) '(("+new line" . "Name it"))))))
    ;; Elsewhere Magit is left alone.
    (let ((other (file-name-as-directory (make-temp-file "roost-other" t))))
      (unwind-protect
          (let ((default-directory other))
            (call-process "git" nil nil nil "init" "-q")
            (magit-status-setup-buffer other)
            (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
              (should-not roost-magit-mode)
              (should-not (string-match-p "^Task:" (buffer-string)))))
        (delete-directory other t)))))

(ert-deftest roost-evil-users-get-roosts-keys-in-magit ()
  (skip-unless (or (featurep 'evil)
                   (progn (setq evil-want-keybinding nil) (require 'evil nil t))))
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (let ((collection (and (require 'evil-collection nil t)
                           (progn (evil-collection-init 'magit) t))))
      (unwind-protect
          (progn
            (evil-mode 1)
            (magit-diff-unstaged)
            (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
              (evil-normal-state)
              (roost-test--goto-line-text "new line")
              (should (eq (key-binding ";") #'roost-note))
              (should (eq (key-binding "@") #'roost-send))
              (should (eq (key-binding "g=") #'roost-diff-whole-file))
              ;; evil-collection's own keys are left as they are.
              (when collection
                (should (eq (key-binding "=") #'magit-diff-less-context))
                (should (eq (key-binding "gr") #'magit-refresh)))))
        (evil-mode -1)))))

(ert-deftest roost-whole-file-diffs-keep-staging ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-status-setup-buffer dir)
    (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
      (goto-char (point-min))
      (re-search-forward "^modified +a.txt")
      (roost-diff-whole-file))
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (should (member "-U1000000" magit-buffer-diff-args))
      (should (equal magit-buffer-diff-files '("a.txt")))
      (should (eq (magit-diff-type) 'unstaged))
      ;; Every line of the file is there.
      (dolist (number (number-sequence 1 10))
        (roost-test--goto-line-text (format "line %d" number))))))

(provide 'roost-test)
