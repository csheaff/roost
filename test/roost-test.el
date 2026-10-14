;;; roost-test.el --- Task protocol and UI tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'roost)
(defvar persp-mode nil)
(defvar persp-modestring-short nil)
(defvar persp-modestring-dividers nil)
(defvar evil-want-keybinding)

(defmacro roost-test--isolated (&rest body)
  (let ((scratch (make-symbol "scratch")))
    ;; Removed afterwards: the sweep runs thousands of tests, and Roost's
    ;; local helper runs in the temporary directory they would fill.
    `(let ((,scratch (list (make-temp-file "roost-projects" t) (make-temp-file "roost-notes" t))))
       (unwind-protect
           (roost-test--isolated-in ,scratch ,@body)
         (dolist (directory ,scratch) (delete-directory directory t))))))

(defmacro roost-test--isolated-in (scratch &rest body)
  "Run BODY with Roost's state isolated, its files in the directories SCRATCH."
  `(let ((roost--tasks (make-hash-table :test 'equal))
         (roost-projects-file (expand-file-name "projects.json" (nth 0 ,scratch)))
         (roost--projects-loaded t) (roost--remembered-projects nil)
         (user-login-name "user")
         (roost--statuses (make-hash-table :test 'equal))
         (roost--seen (make-hash-table :test 'equal))
         (roost--errors (make-hash-table :test 'equal))
         (roost--installed (make-hash-table :test 'equal))
         (roost--refreshing (make-hash-table :test 'equal))
         (roost--revisions (make-hash-table :test 'equal))
         (roost--snapshots (make-hash-table :test 'equal))
         (roost--list-requests (make-hash-table :test 'equal))
         (roost--pull-requests-asked (make-hash-table :test 'equal))
         (roost--full-refresh-pending (make-hash-table :test 'equal))
         (roost--failures (make-hash-table :test 'equal))
         (roost--hosts-loaded t) (roost--remembered-hosts nil)
         (roost-notes-file (expand-file-name "notes.json" (nth 1 ,scratch)))
         (roost--notes nil) (roost--notes-loaded t)
         (roost--requests nil) (roost-notify nil) (roost--current-task nil))
     (set-frame-parameter nil 'roost-task nil)
     ;; Seeing an agent is recorded on its host too; tests that check it say so.
     (cl-letf (((symbol-function 'roost--record-seen) #'ignore)
               ;; A question nobody stubbed would wait for input forever.
               ((symbol-function 'y-or-n-p) (lambda (prompt &rest _) (error "Unexpected question: %s" prompt)))
               ((symbol-function 'yes-or-no-p) (lambda (prompt) (error "Unexpected question: %s" prompt))))
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
       (should (string-match-p "^Answer it in its terminal: RET\n\nWaiting for your answer\nAsks to run make test\n\nPrompt\nfix authentication\n\nAgent's latest reply$"
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
         (should (< (string-match "^fix auth " text) (string-match "^Prompt$" text)
                    (string-match "^Agent's latest reply$" text) (string-match "^Changes$" text)))
         (should (string-match-p "^Agent's latest reply\n## Summary\n" text))
         (should (equal (get-text-property (string-match "Fixed the" text) 'line-prefix text) "  "))
         (should (string-match-p "^Fixed the auth bug in login\\.py\\.\n" text))
         (should-not (string-match-p "\\*\\*\\|`" text)))))))

(ert-deftest roost-opening-a-task-redraws-its-panel-with-the-reply ()
  ;; The host's reply to opening a task can carry a newer status, as when
  ;; you answered the agent meanwhile; the panel kept the older one until
  ;; the next poll.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "permission")))
         callback)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params success &optional _failure) (setq callback success)))
               ((symbol-function 'roost--display-task) #'ignore))
       (save-window-excursion
         (with-current-buffer (get-buffer-create " *panel*")
           (roost-task-info-mode)
           (setq roost--buffer-task-key (roost--key task))
           (switch-to-buffer (current-buffer))
           (roost--render-task-info)
           (should (string-match-p "● permission" (buffer-string)))
           (roost-open-task task)
           (funcall callback (roost-test--task nil "ready"))
           (should (string-match-p "● ready" (buffer-string)))
           (should-not (string-match-p "● permission" (buffer-string))))
         (kill-buffer " *panel*"))))))

(ert-deftest roost-task-panel-leaves-the-conversation-to-the-terminal-on-screen ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((task (roost--cache-task "dev" (append `((request . "Asks to run make test")
                                                     (lastMessage . ,roost-test--reply)
                                                     (diff . "1 file changed, 1 insertion(+)")
                                                     (dirty . t)
                                                     (files ((path . "login.py") (added . 1) (deleted . 0))))
                                                   (roost-test--task nil "permission"))))
            (buffer (roost--task-info-buffer task))
            (on-screen t)
            (draws 0))
       (unwind-protect
           (cl-letf (((symbol-function 'magit-status) #'ignore)
                     ((symbol-function 'roost--panel-beside-terminal-p) (lambda (_) on-screen)))
             (display-buffer-in-side-window buffer (roost--side-window-alist 'right 44))
             (with-current-buffer buffer
               (roost--render-task-info)
               (let ((text (buffer-string)))
                 ;; What to do next, then what the task is for.
                 (should (string-match-p "^Answer it in its terminal: RET\n\nPrompt\nfix authentication\n" text))
                 (should-not (string-match-p "Waiting for your answer\\|Agent's latest reply\\|Fixed the" text))
                 ;; The labels say what is uncommitted, and where notes are written.
                 (should (string-match-p "^Changes\n1 file \\+1 −0\n" text))
                 (should (string-match-p "^  Committed\n  login\\.py  \\+1 −0\nIn a file's diff, ; writes a note for the agent$"
                                         text))
                 (should-not (string-match-p "Actions" text))))
             ;; With the terminal gone from the screen, it has the conversation.
             (advice-add 'roost--render-task-info :before (lambda () (cl-incf draws)) '((name . qa-count)))
             (unwind-protect
                 (progn
                   (roost--redraw-moved-panels)
                   (should (= draws 0))
                   (setq on-screen nil)
                   (roost--redraw-moved-panels)
                   (should (= draws 1))
                   (roost--redraw-moved-panels)
                   (should (= draws 1)))
               (advice-remove 'roost--render-task-info 'qa-count))
             (with-current-buffer buffer
               (should (string-match-p "^Waiting for your answer$" (buffer-string)))
               (should (string-match-p "^Agent's latest reply$" (buffer-string)))))
         (kill-buffer buffer))))))

(ert-deftest roost-task-panel-is-beside-a-terminal-only-in-its-frame ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((task (roost--cache-task "dev" (roost-test--task)))
            (panel (roost--task-info-buffer task))
            (terminal (get-buffer-create " *terminal stand-in*"))
            (main (selected-window)))
       (unwind-protect
           (cl-letf (((symbol-function 'roost--terminal-shows-p)
                      (lambda (_task _panes) (eq (current-buffer) terminal))))
             (set-window-buffer main panel)
             (with-current-buffer panel
               ;; Alone, the panel keeps the conversation.
               (should-not (roost--panel-beside-terminal-p task))
               (set-window-buffer (split-window-right) terminal)
               (should (roost--panel-beside-terminal-p task))
               ;; Hidden, it has no terminal beside it.
               (set-window-buffer main (get-buffer-create "*scratch*"))
               (should-not (roost--panel-beside-terminal-p task))))
         (kill-buffer panel)
         (kill-buffer terminal))))))

(ert-deftest roost-replies-show-link-text-and-open-links ()
  (roost-test--isolated
   (let* ((reply (concat "Opened [**PR #22**](https://github.com/o/r/pull/22). "
                         "See https://x.example/a_b, or **https://y.example**.\n"
                         "Run `curl https://z.example/p` and keep `[a](https://b.example)`."))
          (text (roost--strip-markdown reply t)))
     ;; Without buttons, a Markdown link shows only its text; inside code it
     ;; is code.
     (should (equal (roost--strip-markdown reply)
                    (concat "Opened PR #22. See https://x.example/a_b, or https://y.example.\n"
                            "Run curl https://z.example/p and keep [a](https://b.example).")))
     (should (equal (substring-no-properties text) (roost--strip-markdown reply)))
     (pcase-dolist (`(,shown . ,url) '(("PR #22" . "https://github.com/o/r/pull/22")
                                       ("https://x.example/a_b" . "https://x.example/a_b")
                                       ("https://y.example" . "https://y.example")
                                       ("https://z.example/p" . "https://z.example/p")))
       (let ((at (string-search shown text)))
         (should (equal (get-text-property at 'button-data text) url))
         (should (equal (get-text-property (+ at (length shown) -1) 'button-data text) url))
         (should-not (equal (get-text-property (+ at (length shown)) 'button-data text) url))))
     (should-not (get-text-property (string-search "Opened" text) 'button text))
     ;; A dashboard row's summary has no buttons: RET there opens the task.
     (let ((summary (roost--last-message-summary `((lastMessage . ,reply)))))
       (should (equal summary "Opened PR #22. See https://x.example/a_b, or https://y.example."))
       (should-not (text-property-not-all 0 (length summary) 'button nil summary)))
     ;; A URL keeps the brackets and trailing characters that are its own,
     ;; and leaves out the prose and emphasis around it.
     (pcase-dolist (`(,in ,shown ,url)
                    '(("See https://en.wikipedia.org/wiki/Foo_(bar)."
                       "See https://en.wikipedia.org/wiki/Foo_(bar)."
                       "https://en.wikipedia.org/wiki/Foo_(bar)")
                      ("(see https://x.example/a)" "(see https://x.example/a)" "https://x.example/a")
                      ("Open https://example.test/page_" "Open https://example.test/page_"
                       "https://example.test/page_")
                      ("_https://x.example/i_ now" "https://x.example/i now" "https://x.example/i")
                      ("[article](https://en.wikipedia.org/wiki/Foo_(bar))" "article"
                       "https://en.wikipedia.org/wiki/Foo_(bar)")
                      ("[article](https://example.test/Foo_(bar_(baz)))" "article"
                       "https://example.test/Foo_(bar_(baz))")))
       (let ((out (roost--strip-markdown in t)))
         (should (equal (substring-no-properties out) shown))
         (should (equal (roost--strip-markdown in) shown))
         (let* ((at (text-property-not-all 0 (length out) 'button-data nil out))
                (end (next-single-property-change at 'button-data out (length out))))
           (should (equal (get-text-property at 'button-data out) url))
           (should (equal (substring-no-properties out at end)
                          (if (equal shown "article") "article" url))))))
     ;; In the task panel, RET or a click on a link opens it.
     (let ((task (roost--cache-task "dev" (append `((lastMessage . ,reply)) (roost-test--task))))
           opened)
       (with-temp-buffer
         (roost-task-info-mode)
         (setq roost--buffer-task-key (roost--key task))
         (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url opened))))
           (roost--render-task-info)
           (goto-char (point-min))
           (search-forward "PR #22")
           (push-button (match-beginning 0))
           (should (equal opened '("https://github.com/o/r/pull/22")))))))))

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
       (should (string-match-p "^Collapse prompt\nFix the login\\.\n\nRun the tests afterwards\\.$"
                               (buffer-string)))
       ;; Point is on the way back, not somewhere in the prompt.
       (should (looking-at-p "Collapse prompt"))
       (push-button)
       (should (string-match-p "^Fix the login\\.\nShow the whole prompt$" (buffer-string)))
       (should-not (string-match-p "Run the tests" (buffer-string)))
       (should (looking-at-p "Show the whole prompt"))))))

(ert-deftest roost-a-draft-from-a-tiled-pane-opens-beside-the-tiles ()
  ;; Shown in the pane's window, the draft was taken back when tmux-control
  ;; next arranged its panes, and what you typed went to the terminal.
  (roost-test--isolated
   (let ((pane (generate-new-buffer " pane"))
         (magit (generate-new-buffer " magit"))
         (draft (generate-new-buffer " draft"))
         (another (generate-new-buffer " another draft"))
         (tiled t))
     (unwind-protect
         (cl-letf (((symbol-function 'tmux-control-tiled-p) (lambda () tiled)))
           (with-current-buffer pane (setq major-mode 'tmux-control-mode))
           (save-window-excursion
             (delete-other-windows)
             (let ((top (selected-window))
                   (bottom (split-window)))
               (set-window-buffer top pane)
               (set-window-buffer bottom magit)
               (select-window top)
               ;; Another window there is: the draft takes it.
               (roost--pop-to-buffer-in-place draft)
               (should (eq (selected-window) bottom))
               (should (eq (window-buffer top) pane))
               ;; Not one kept for its buffer.
               (set-window-dedicated-p bottom t)
               (select-window top)
               (roost--pop-to-buffer-in-place another)
               (should (eq (window-buffer bottom) draft))
               (delete-window (selected-window))
               (set-window-dedicated-p bottom nil)
               ;; With none, a new one below.
               (set-window-buffer bottom pane)
               (select-window top)
               (roost--pop-to-buffer-in-place another)
               (should (= (length (window-list)) 3))
               (should (eq (window-buffer top) pane))
               (should-not (memq (selected-window) (list top bottom)))
               ;; Not tiled, the window you are in.
               (setq tiled nil)
               (select-window top)
               (roost--pop-to-buffer-in-place draft)
               (should (eq (window-buffer top) draft)))))
       (mapc #'kill-buffer (list pane magit draft another))))))

(ert-deftest roost-a-task-opens-in-place-of-another-tasks-terminal ()
  ;; Opening one task with Magit selected below another's terminal put the
  ;; task in Magit's window and left the other terminal on screen.
  (roost-test--isolated
   (let ((shown (roost--cache-task "dev" (roost-test--task "1111111111111111")))
         (opened (roost--cache-task "dev" (append '((session . "roost-other"))
                                                  (roost-test--task "2222222222222222"))))
         (terminal (generate-new-buffer " terminal"))
         (magit (generate-new-buffer " magit")))
     (unwind-protect
         (roost-test--with-tmux-buffers
          (save-window-excursion
            (delete-other-windows)
            (with-current-buffer terminal
              (setq major-mode 'tmux-control-mode
                    roost-test--tmux (list :host "dev" :socket "main" :session (roost--field shown 'session))))
            (let ((top (selected-window))
                  (bottom (split-window)))
              (set-window-buffer top terminal)
              (set-window-buffer bottom magit)
              (select-window bottom)
              (should (eq (roost--terminal-window-for opened) top))
              ;; The task's own panes, tiled, keep their grid.
              (with-current-buffer terminal
                (setq major-mode 'tmux-control-mode
                      roost-test--tmux (list :host "dev" :socket "main" :session "roost-other")))
              (should-not (roost--terminal-window-for opened))
              ;; With no task's terminal on screen, the selected window it is.
              (set-window-buffer top magit)
              (should-not (roost--terminal-window-for opened)))))
       (kill-buffer terminal)
       (kill-buffer magit)))))

(ert-deftest roost-an-ended-terminal-gives-way-to-no-other-tasks ()
  ;; Stopping a task put another task's terminal, shown earlier in the
  ;; window, back in its place, beside the stopped task's panel.
  (roost-test--isolated
   (let ((ended (generate-new-buffer "ended terminal"))
         (other (generate-new-buffer "other terminal"))
         (code (generate-new-buffer "code.py")))
     (unwind-protect
         (roost-test--with-tmux-buffers
          (let ((task (roost--cache-task "dev" (roost-test--task "1111111111111111")))
                (another (roost--cache-task "dev" (append '((session . "roost-another"))
                                                          (roost-test--task "2222222222222222")))))
            (with-current-buffer ended
              (setq major-mode 'tmux-control-mode
                    roost-test--tmux (list :host "dev" :socket "main" :session (roost--field task 'session))))
            (with-current-buffer other
              (setq major-mode 'tmux-control-mode
                    roost-test--tmux (list :host "dev" :socket "main" :session (roost--field another 'session))))
            (save-window-excursion
              (delete-other-windows)
              (switch-to-buffer code)
              (switch-to-buffer other)
              (switch-to-buffer ended)
              (roost--discard-terminal (list ended))
              (should-not (buffer-live-p ended))
              (should (eq (window-buffer) code)))))
       (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) (list ended other code))))))

(ert-deftest roost-discarding-points-to-the-key-for-the-work-it-holds ()
  ;; Work not yet committed can't be merged: it says how to commit it.
  (roost-test--isolated
   (pcase-dolist (`(,fields . ,hint) '((((dirty . t) (ahead . 0)) . "r commits it in Magit")
                                       (((dirty) (ahead . 2)) . "m merges it")))
     (let ((task (roost--cache-task "dev" (append fields (roost-test--task nil "ready"))))
           asked)
       (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) nil)))
         (roost-retire task))
       (should (string-match-p (regexp-quote (format "(%s).  Discard it?" hint)) asked))))))

(ert-deftest roost-an-unreachable-host-fits-the-dashboard ()
  ;; Its line held the whole ssh error, cut off at the window's edge.
  (roost-test--isolated
   (let ((roost-hosts '("far")))
     (puthash "far" "ssh: Could not resolve hostname far: nodename nor servname provided, or not known\nmore"
              roost--errors)
     (with-temp-buffer
       (roost-dashboard-mode)
       (cl-letf (((symbol-function 'roost--usable-width) (lambda (_) 40)))
         (set-window-buffer (selected-window) (current-buffer))
         (roost--render-dashboard))
       (goto-char (point-min))
       (should (looking-at "far is unreachable"))
       (should (<= (string-width (buffer-substring (line-beginning-position) (line-end-position))) 40))
       (should (string-match-p "nodename" (get-text-property (point) 'help-echo)))))))

(ert-deftest roost-a-dashboard-heading-keeps-the-end-of-a-long-path ()
  (roost-test--isolated
   (should (equal (roost--truncate-start "~/code/roost" 20) "~/code/roost"))
   (should (equal (roost--truncate-start "/a/very/long/path/to/notes" 10) "…/to/notes"))
   (roost--cache-task "dev" (append '((repo . "/home/user/a/very/long/path/that/goes/on/to/the/notes"))
                                    (roost-test--task)))
   (with-temp-buffer
     (roost-dashboard-mode)
     (cl-letf (((symbol-function 'roost--usable-width) (lambda (_) 40)))
       (let ((window (selected-window)))
         (set-window-buffer window (current-buffer))
         (roost--render-dashboard)))
     (goto-char (point-min))
     (should (re-search-forward "^dev · notes  ….*/notes$" nil t))
     (should (<= (string-width (buffer-substring (line-beginning-position) (line-end-position))) 40)))))

(ert-deftest roost-a-panel-beside-a-terminal-just-connected-leaves-the-reply-to-it ()
  ;; Before tmux named the active pane, the panel showed the reply beside
  ;; the terminal, until the next redraw.
  (roost-test--isolated
   (let ((terminal (generate-new-buffer "terminal"))
         (task (roost--cache-task "dev" (append `((lastMessage . "All done here."))
                                                (roost-test--task nil "ready")))))
     (unwind-protect
         (roost-test--with-tmux-buffers
          (save-window-excursion
            (delete-other-windows)
            (with-temp-buffer
              (roost-task-info-mode)
              (setq roost--buffer-task-key (roost--key task))
              (set-window-buffer (selected-window) terminal)
              (set-window-buffer (split-window nil nil 'right) (current-buffer))
              (with-current-buffer terminal (setq major-mode 'tmux-control-mode))
              (pcase-dolist (`(,pane . ,reply) '((nil . nil) ("%12" . nil) ("%99" . t)))
                (with-current-buffer terminal
                  (setq roost-test--tmux (list :host "dev" :socket "main"
                                               :session (roost--field task 'session) :pane pane)))
                (roost--render-task-info)
                (should (eq reply (and (string-search "All done here." (buffer-string)) t))))
              ;; A session tasks share, from before each had its own, is
              ;; no one's terminal.
              (roost--cache-task "dev" (roost-test--task "fedcba9876543210" "ready"))
              (with-current-buffer terminal (setq roost-test--tmux (plist-put roost-test--tmux :pane nil)))
              (roost--render-task-info)
              (should (string-search "All done here." (buffer-string))))))
       (kill-buffer terminal)))))

(ert-deftest roost-a-task-is-shown-once-the-minibuffer-is-done ()
  ;; A reply opening a task while a question was asked took the answer to
  ;; the task's terminal.
  (roost-test--isolated
   (let ((minibuffer t) (shown nil))
     (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () minibuffer)))
       (roost--when-out-of-minibuffer (lambda () (push 'shown shown)))
       (should-not shown)
       (setq minibuffer nil)
       (run-hooks 'minibuffer-exit-hook)
       (should-not shown)
       (accept-process-output nil 0.05)
       (should (equal shown '(shown)))
       ;; With no minibuffer, at once.
       (roost--when-out-of-minibuffer (lambda () (push 'again shown)))
       (should (equal shown '(again shown)))))))

(ert-deftest roost-closing-a-frame-marks-the-task-of-the-frame-left ()
  ;; The sidebar marked the task opened in a frame since closed.
  (roost-test--isolated
   (let ((left (roost--cache-task "dev" (roost-test--task "1111111111111111")))
         (closed (roost--cache-task "dev" (roost-test--task "2222222222222222"))))
     (set-frame-parameter nil 'roost-task (roost--key left))
     (setq roost--current-task (roost--key closed))
     (roost--frame-deleted nil)
     (should (equal roost--current-task (roost--key left)))
     ;; A task marked that a frame still shows stays marked.
     (setq roost--current-task (roost--key left))
     (set-frame-parameter nil 'roost-task (roost--key left))
     (roost--frame-deleted nil)
     (should (equal roost--current-task (roost--key left))))))

(ert-deftest roost-a-shared-session-is-no-tasks-terminal ()
  ;; Tasks from before each had a session of its own can share one.
  (roost-test--isolated
   (let ((terminal (generate-new-buffer " terminal")))
     (unwind-protect
         (roost-test--with-tmux-buffers
          (let ((one (roost--cache-task "dev" (roost-test--task "1111111111111111"))))
            (with-current-buffer terminal
              (setq major-mode 'tmux-control-mode
                    roost-test--tmux (list :host "dev" :socket "main" :session (roost--field one 'session))))
            (should (eq (roost--terminal-task terminal) one))
            (roost--cache-task "dev" (roost-test--task "2222222222222222"))
            (should-not (roost--terminal-task terminal))))
       (kill-buffer terminal)))))

(ert-deftest roost-a-frame-whose-task-is-gone-follows-the-terminal-it-shows ()
  ;; Once a task is merged, its window shows another task's terminal; the
  ;; panel follows that task, rather than no task at all.
  (roost-test--isolated
   (let ((shown (roost--cache-task "dev" (roost-test--task "1111111111111111")))
         (terminal (generate-new-buffer " terminal")))
     (unwind-protect
         (roost-test--with-tmux-buffers
          (save-window-excursion
            (delete-other-windows)
            (with-current-buffer terminal
              (setq major-mode 'tmux-control-mode
                    roost-test--tmux (list :host "dev" :socket "main" :session (roost--field shown 'session))))
            (set-window-buffer (selected-window) terminal)
            (set-frame-parameter nil 'roost-task '("dev" "2222222222222222"))
            (setq roost--current-task '("dev" "2222222222222222"))
            ;; Looking does not change it; a redraw, panel or not, does.
            (should-not (roost--frame-task))
            (let ((roost-task-panel-mode nil))
              (roost--redraw))
            (should (eq (roost--frame-task) shown))
            ;; The sidebar marks it, the task last opened being gone too.
            (should (equal roost--current-task (roost--key shown)))
            ;; From the terminal used last, though Magit was used since.
            (set-frame-parameter nil 'roost-task '("dev" "3333333333333333"))
            (let ((magit (split-window)))
              (set-window-buffer magit (get-buffer-create "*scratch*"))
              (select-window magit)
              (roost--redraw)
              (should (eq (roost--frame-task) shown))
              (delete-window magit))
            ;; It keeps it, as if opened there, when a draft then covers
            ;; the terminal: the panel stays, and so do the widths.
            (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
            (roost--redraw)
            (should (eq (roost--frame-task) shown))
            ;; While the task it names is there, the frame keeps that one.
            (let ((own (roost--cache-task "dev" (roost-test--task "2222222222222222"))))
              (set-frame-parameter nil 'roost-task (roost--key own))
              (set-window-buffer (selected-window) terminal)
              (should (eq (roost--frame-task) own)))))
       (kill-buffer terminal)))))

(ert-deftest roost-task-panel-keeps-the-status-on-one-line ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((name . "ask-git-status-short"))
                                                (roost-test--task nil "permission")))))
     (with-temp-buffer
       (setq roost--buffer-task-key (roost--key task))
       ;; Narrow, the status goes below the name rather than breaking.
       (cl-letf (((symbol-function 'roost--task-info-width) (lambda () 40)))
         (roost--render-task-info))
       (should (string-match-p "\\`ask-git-status-short\n.*permission for [^\n]+\n" (buffer-string)))
       (cl-letf (((symbol-function 'roost--task-info-width) (lambda () 100)))
         (roost--render-task-info))
       (should (string-match-p "\\`ask-git-status-short   .*permission for [^\n]+\n" (buffer-string)))))))

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
         (should (looking-at-p "Show the whole reply"))
         (goto-char (point-min))
         (search-forward "Show the whole reply")
         (push-button (1- (point)))
         (setf (alist-get 'lastMessage task) (concat reply "\n\nA new response arrived."))
         (roost--render-task-info)
         (should-not roost--expanded-reply)
         (should-not (string-match-p "A new response arrived" (buffer-string)))
         (should (string-match-p "^Changes$" (buffer-string)))
         (should (string-match-p "^Details$" (buffer-string))))))))

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

(ert-deftest roost-prose-leaves-tables-and-code-in-their-font ()
  (roost-test--isolated
   (let ((prose (lambda (text line)
                  (memq 'roost-prose (ensure-list (get-text-property (string-search line text) 'face text))))))
     (let ((text (roost--prose "Done, see below.\n| a | b |\n```\nx = 1\n```\n    indented\nThe end.")))
       (should (funcall prose text "Done, see below."))
       (should (funcall prose text "The end."))
       (should-not (funcall prose text "| a | b |"))
       (should-not (funcall prose text "x = 1"))
       (should-not (funcall prose text "    indented")))
     ;; A fence closes only with as long a run of its own marker.
     (let ((text (roost--prose "````\n```\nstill code\n~~~\n````\nProse again.")))
       (should-not (funcall prose text "still code"))
       (should (funcall prose text "Prose again.")))
     ;; Indented four spaces, a fence is indented code and opens no block.
     (should (funcall prose (roost--prose "Before.\n    ```\nAfter.") "After."))
     ;; A table without outer pipes is found by its delimiter row.
     (let ((text (roost--prose "Before.\nName | Does\n--- | :---:\nadd | adds a note\nAfter.")))
       (should (funcall prose text "Before."))
       (should-not (funcall prose text "Name | Does"))
       (should-not (funcall prose text "--- | :---:"))
       (should-not (funcall prose text "add | adds a note"))
       (should (funcall prose text "After."))))
   ;; In batch a pixel is a column, so text is cut and wrapped as by columns.
   (should (= (roost--text-width "a界") 3))
   (should (equal (roost--truncate-width "short" 10) "short"))
   (should (equal (roost--truncate-width "one two three" 8) "one two…"))
   (should (equal (roost--wrap-width "one two three\nfour" 7) '("one two" "three" "four")))
   (should (equal (roost--wrap-width "one two three four" 3 1) '("one" "two")))
   (should (equal (roost--wrap-width "a  b" 10) '("a  b")))
   (should (equal (roost--wrap-width "one\n\ntwo" 10) '("one" "" "two")))
   ;; Repeated spaces at a break leave no blank line, and a line's own
   ;; indentation stays.
   (should (equal (roost--wrap-width "1234567890  abcdefghij" 10) '("1234567890" "abcdefghij")))
   (should (equal (roost--wrap-width "  - one two" 8) '("  - one" "two")))
   ;; Spaces keep the face of the text around them.
   (let ((line (car (roost--wrap-width (propertize "one two three" 'face 'roost-prose) 7))))
     (should (equal line "one two"))
     (should (eq (get-text-property 3 'face line) 'roost-prose)))))

(ert-deftest roost-measuring-text-leaves-a-shown-buffer-as-it-was-drawn ()
  (roost-test--isolated
   ;; Measured in a window showing the buffer, as a panel beside a
   ;; terminal is while it is redrawn.
   (let ((task (roost--cache-task "dev" (append `((lastMessage . ,roost-test--reply))
                                                (roost-test--task nil "permission")))))
     (with-temp-buffer
       (let ((window (split-window)))
         (unwind-protect
             (progn
               (set-window-buffer window (current-buffer))
               (insert "one\ntwo\n")
               (set-window-point window 1)
               (goto-char (point-max))
               (roost--text-width "word")
               (should (= (point) (point-max)))
               (roost-task-info-mode)
               (setq roost--buffer-task-key (roost--key task))
               (roost--render-task-info)
               (should (string-prefix-p "fix auth" (buffer-string)))
               (should (< (string-search "Agent's latest reply" (buffer-string))
                          (string-search "Changes" (buffer-string))
                          (string-search "Details" (buffer-string)))))
           (delete-window window)))))))

(ert-deftest roost-a-dashboard-summary-cut-short-says-so ()
  (roost-test--isolated
   ;; A narrow proportional font fits four letters in a column, so the
   ;; first cut, at three times the room, is the one that shows.
   (cl-letf (((symbol-function 'roost--text-width) (lambda (string) (/ (string-width string) 4.0))))
     (let* ((task (append `((lastMessage . ,(mapconcat #'identity (make-list 200 "iiii") " ")))
                          (roost-test--task)))
            (row (roost--dashboard-row task (roost--dashboard-layout (list task) 120) 120)))
       (should (string-suffix-p "…" row))))))

(ert-deftest roost-status-words-are-coloured-only-when-you-are-needed ()
  (roost-test--isolated
   (should (eq (roost--status-word-face "permission") 'roost-status-permission))
   (should (eq (roost--status-word-face "failed") 'roost-status-failed))
   (should-not (roost--status-word-face "ready"))
   (should (eq (roost--status-word-face "running") 'roost-dim))
   (should (eq (roost--status-word-face "idle") 'roost-dim))
   (let ((task (roost--cache-task "dev" (roost-test--task nil "running"))))
     (should (eq (get-text-property 0 'face (roost--summary (list task))) 'roost-dim))
     (with-temp-buffer
       (roost-task-info-mode)
       (setq roost--buffer-task-key (roost--key task))
       (roost--render-task-info)
       ;; Sections are apart by half a line.
       (goto-char (point-min))
       (search-forward "\nChanges\n")
       (should (equal (get-text-property (match-beginning 0) 'face) '(:height 0.5)))))))

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
       (should (string-match-p "^Its last turn failed; open it to try its last prompt again: RET$"
                               (buffer-string)))
       (should-not (string-match-p "resumes" (buffer-string)))
       (should (string-match-p (concat "Last error: " (regexp-quote error)) (buffer-string)))
       ;; An agent that exited is resumed.
       (roost--cache-task "dev" (append '((live)) (roost-test--task nil "failed")))
       (roost--render-task-info)
       (should (string-match-p "^fix auth   ● failed for" (buffer-string)))
       (should (string-match-p "^RET shows its last output; s resumes its conversation$" (buffer-string))))
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

(ert-deftest roost-notifies-when-a-starting-agent-asks-or-fails ()
  ;; Polls 15 seconds apart, with Emacs in the background, can see an
  ;; agent go from starting to asking without the turn in between.
  (roost-test--isolated
   (roost-test--without-inspect
    (let* ((roost-notify t) notices
           (roost-notify-function (lambda (title _body) (push title notices))))
      (roost--cache-task "dev" (roost-test--task nil "starting"))
      (roost--cache-task "dev" (roost-test--task nil "ready"))
      (should-not notices)
      (roost--cache-task "dev" (roost-test--task "1123456789abcdef" "starting"))
      (roost--cache-task "dev" (roost-test--task "1123456789abcdef" "permission"))
      (roost--cache-task "dev" (roost-test--task "2123456789abcdef" "starting"))
      (roost--cache-task "dev" (roost-test--task "2123456789abcdef" "failed"))
      (should (equal notices '("Roost: fix auth — failed" "Roost: fix auth — permission")))))))

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
       ;; Each list request is counted, and Roost notes which one the list it
       ;; holds answers: b's first, while its second measures the new task.
       (should (equal (list (gethash "a" roost--list-requests) (gethash "b" roost--list-requests)) '(1 2)))
       (should (equal (list (gethash "a" roost--snapshots) (gethash "b" roost--snapshots)) '(nil 1)))
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
    (should (equal (car (last argv)) (concat tmux-control-remote-tmux-socket-setup " && exec python3 -I -c " (shell-quote-argument code))))
    (should (equal (roost--python-command nil code) (list "python3" "-I" "-c" code))))))

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

(ert-deftest roost-open-leaves-what-you-showed-before-the-reply ()
  ;; C-c C-e just after opening a task showed the pager, which the host's
  ;; reply then replaced with the terminal.
  (roost-test--isolated
   (let (callback displayed)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params success &optional _failure) (setq callback success)))
               ((symbol-function 'roost--display-task) (lambda (task) (setq displayed (roost--field task 'id)))))
       (save-window-excursion
         (switch-to-buffer (get-buffer-create " *before*"))
         (roost-open-task (roost-test--task))
         (switch-to-buffer (get-buffer-create " *pager*"))
         (funcall callback (roost-test--task))
         (should-not displayed)
         ;; Nor when you have moved to another window since, the one it was
         ;; opened from still showing what it did.
         (delete-other-windows)
         (switch-to-buffer " *before*")
         (roost-open-task (roost-test--task))
         (select-window (split-window))
         (funcall callback (roost-test--task))
         (should-not displayed)
         (delete-other-windows)
         (switch-to-buffer " *before*")
         (roost-open-task (roost-test--task))
         (funcall callback (roost-test--task))
         (should (equal displayed "0123456789abcdef")))
       (kill-buffer " *before*")
       (kill-buffer " *pager*")))))

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

(ert-deftest roost-new-and-resumed-tasks-say-whether-to-relay-agent-status ()
  (roost-test--isolated
   (let (requests)
     (cl-letf (((symbol-function 'hack-dir-local-variables-non-file-buffer) #'ignore)
               ((symbol-function 'roost--remember-host) #'ignore)
               ((symbol-function 'roost-watch-mode) #'ignore)
               ((symbol-function 'roost-open-task) #'ignore)
               ((symbol-function 'roost--request)
                (lambda (_host action params success &optional _failure)
                  (push (cons action (alist-get 'programStatus params)) requests)
                  (funcall success (roost-test--task)))))
       (roost-new-task "/ssh:dev:/repo/" "plain")
       (let ((roost-program-status t))
         (roost-new-task "/ssh:dev:/repo/" "relayed")
         (roost-resume (gethash '("dev" "0123456789abcdef") roost--tasks)))
       (should (equal (reverse requests) '(("create" . :false) ("create" . t) ("resume" . t))))))))

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

(ert-deftest roost-terminal-leaves-the-workspace-of-another-task ()
  (roost-test--isolated
   (let* ((a (roost--cache-task nil (roost-test--task "1111111111111111")))
          (b (roost--cache-task nil (roost-test--task "2222222222222222")))
          (persp-mode t) removed)
     (setf (alist-get 'session a) "roost-a" (alist-get 'session b) "roost-b")
     (roost--cache-task nil a)
     (roost--cache-task nil b)
     (cl-letf (((symbol-function 'persp-remove-buffer) (lambda (buffer) (push buffer removed)))
               ((symbol-function 'tmux-control-buffer-host) (lambda () nil))
               ((symbol-function 'tmux-control-buffer-socket-name) (lambda () (roost--field a 'socket)))
               ((symbol-function 'tmux-control-buffer-session) (lambda () "roost-a"))
               ((symbol-function 'persp-current-name) (lambda () (roost--perspective-name b))))
       (with-temp-buffer
         (roost--keep-terminal-in-its-workspace)
         (should (equal removed (list (current-buffer)))))
       (setq removed nil)
       (cl-letf (((symbol-function 'persp-current-name) (lambda () (roost--perspective-name a))))
         (with-temp-buffer
           (roost--keep-terminal-in-its-workspace)
           (should-not removed)))))))

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
                      (lambda (_prompt table &rest _)
                        ;; Newest first, as gh lists them, whatever the completion UI.
                        (should (eq (alist-get 'display-sort-function (cdr (funcall table "" nil 'metadata)))
                                    'identity))
                        (nth (if created 1 0) (funcall table "" nil t))))
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
                                   (substring-no-properties (roost--dispatch-task-description)))))))
     ;; What to do next shows below, as in the task panel.
     (roost--cache-task "dev" (append '((dirty . 2)) (roost-test--task)))
     (with-temp-buffer
       (setq roost--buffer-task-key (roost--key task))
       (let ((transient--original-buffer (current-buffer)))
         (should (equal (substring-no-properties (roost--dispatch-task-description))
                        "Task fix auth (ready)\nReview and commit its changes in Magit: r")))))
   (let ((transient--original-buffer nil))
     (with-temp-buffer
       (should (equal (roost--dispatch-task-description) "Task (chosen when needed)"))))
   ;; The 0.2 alias of roost-dispatch to roost-new-task must not shadow the menu.
   (should (get 'roost-dispatch 'transient--prefix))
   (should-not (eq (indirect-function 'roost-dispatch) (indirect-function 'roost-new-task)))
   (should (eq (lookup-key roost-dashboard-mode-map "h") 'roost-dispatch))
   (should (eq (lookup-key roost-task-info-mode-map "h") 'roost-dispatch))))

(ert-deftest roost-search-shows-each-hosts-messages-and-opens-live-tasks ()
  (roost-test--isolated
   (let ((roost-hosts '("dev" "box")) requests opened fetched)
     (roost--cache-task "dev" (roost-test--task))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (host action params success failure)
                  (push (list host action params success failure) requests)))
               ((symbol-function 'roost--refresh-host) (lambda (host &rest _) (push host fetched)))
               ((symbol-function 'roost-open-task) (lambda (task) (setq opened task))))
       (unwind-protect
           (save-window-excursion
             (roost-search "  csv COMMAS ")
             (set-buffer roost--search-buffer)
             (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r) (nth 2 r))) (reverse requests))
                            '(("dev" "search" ((query . "csv COMMAS")))
                              ("box" "search" ((query . "csv COMMAS"))))))
             (should (string-match-p "Searching dev, box…" (buffer-string)))
             (let ((dev (assoc "dev" requests)) (box (assoc "box" requests)))
               (funcall (nth 3 dev)
                        '((tasks ((id . "0123456789abcdef") (name . "fix auth") (repo . "/home/user/shop")
                                  (hits ((at . "2026-10-01T10:01:00Z") (role . "user") (session . "s1") (line . 3)
                                         (snippet . "Quote CSV fields with commas")
                                         (text . "Quote CSV fields with commas, please."))
                                        ((at . "2026-10-01T10:02:00Z") (role . "assistant") (session . "s1") (line . 4)
                                         (snippet . "Done: CSV commas quoted") (text . "Done: CSV commas quoted.")))
                                  (more . 0))
                                 ;; Live, but not fetched yet, as before Roost first watches.
                                 ((id . "1111111111111111") (name . "fresh task") (repo . "/home/user/shop")
                                  (hits ((at . "2026-10-02T10:00:00Z") (role . "user") (session . "s3") (line . 1)
                                         (snippet . "Fresh CSV commas") (text . "Fresh CSV commas")))
                                  (more . 0))
                                 ;; Live too, but retired before Roost fetches it.
                                 ((id . "2222222222222222") (name . "gone task") (repo . "/home/user/shop")
                                  (hits ((at . "2026-09-30T10:00:00Z") (role . "user") (session . "s4") (line . 1)
                                         (snippet . "Gone CSV commas") (text . "Gone CSV commas")))
                                  (more . 0))
                                 ((past . t) (key . "0a1b2c3d4e/csv-import-9f8e7d") (name . "csv import") (repo)
                                  (hits ((at . "2026-10-03T10:00:00Z") (role . "user") (session . "s2") (line . 7)
                                         (snippet . "Import CSV with commas")
                                         (text . "Import CSV with commas\nin quotes")))
                                  (more . 3)))
                          (moreTasks . 0)))
               (should (string-match-p "Searching box…" (buffer-string)))
               ;; Roost fetches the tasks of a host that has one it lacks.
               (should (equal fetched '("dev")))
               (funcall (nth 4 box) "ssh: no route")
               (let ((shown (buffer-string)))
                 (should-not (string-match-p "Searching" shown))
                 (should (string-match-p "^Could not search box: ssh: no route$" shown))
                 ;; The task with the newest message first; a past task has no status.
                 (should (string-match-p (concat "csv import  dev  past task\n"
                                                 "  3 earlier messages match too\n"
                                                 "  2026-10-0.*You    Import CSV with commas\n"
                                                 "\nfresh task  dev · shop\n"
                                                 "  2026-10-0.*You    Fresh CSV commas\n"
                                                 "\nfix auth  dev · shop  ready\n"
                                                 "  2026-10-0.*You    Quote CSV fields with commas\n"
                                                 "  2026-10-0.*Claude Done: CSV commas quoted\n")
                                         shown)))
               ;; The words searched for are highlighted where a word starts.
               (goto-char (point-min))
               (search-forward "Quote CSV")
               (should (memq 'roost-search-match (ensure-list (get-text-property (1- (point)) 'face))))
               (let ((shown (roost--search-highlight "latest tests" '("test"))))
                 (should-not (get-text-property 3 'face shown))
                 (should (memq 'roost-search-match (ensure-list (get-text-property 7 'face shown)))))
               ;; Point starts on the first message: a past task's, which shows
               ;; its whole message rather than opening anything.
               (goto-char (point-min))
               (roost--render-search)
               (should (string-match-p "Import CSV" (thing-at-point 'line)))
               (should-not (roost--task-at-point))
               (let ((id (get-text-property (point) 'roost-search-id)))
                 (roost-search-open)
                 (should (equal (get-text-property (point) 'roost-search-id) id))
                 (should (string-match-p "with commas\nin quotes\n" (buffer-string)))
                 ;; A long line of it is wrapped, which the buffer's lines are not.
                 (should (equal (roost--search-wrap (concat (make-string 30 ?a) " " (make-string 30 ?b) "\nshort") 40)
                                (concat (make-string 30 ?a) "\n" (make-string 30 ?b) "\nshort")))
                 ;; A word longer than the width, such as a URL, is broken within.
                 (should (equal (roost--search-wrap (concat "see " (make-string 50 ?x)) 20)
                                (concat "see\n" (make-string 20 ?x) "\n" (make-string 20 ?x) "\n" (make-string 10 ?x))))
                 ;; Widths are columns: a CJK character takes two.
                 (let ((wrapped (roost--search-wrap (make-string 30 ?漢) 40)))
                   (should (seq-every-p (lambda (line) (<= (string-width line) 40)) (split-string wrapped "\n")))
                   (should (equal (string-replace "\n" "" wrapped) (make-string 30 ?漢))))
                 (roost-search-toggle)
                 (should-not (string-match-p "in quotes" (buffer-string))))
               ;; One not fetched yet can't open until it is, and Roost fetches it.
               (roost-search-next)
               (should (string-match-p "Fresh CSV" (thing-at-point 'line)))
               ;; A message its line shows whole has no more to show.
               (let ((shown (buffer-string)))
                 (should-error (roost-search-toggle) :type 'user-error)
                 (should (equal (buffer-string) shown)))
               (setq fetched nil)
               (should-error (roost-search-open) :type 'user-error)
               (should (equal fetched '("dev")))
               (should (string-match-p "^gone task  dev · shop$" (buffer-string)))
               ;; The host's list arrives, and its redraw shows the task; a
               ;; task the list lacks has been retired since.
               (roost--apply-snapshot "dev" (list (roost-test--task)
                                                  (append '((name . "fresh task"))
                                                          (roost-test--task "1111111111111111" "running"))))
               (roost--redraw)
               (should (string-match-p "^fresh task  dev · shop  running$" (buffer-string)))
               (should (string-match-p "^gone task  dev · shop  past task$" (buffer-string)))
               ;; Nor can a past task's, which says there is nothing to open.
               (save-excursion
                 (goto-char (point-min))
                 (search-forward "Gone CSV")
                 (let ((shown (buffer-string)))
                   (should (string-match-p "Nothing to open: gone task is no longer a task"
                                           (cadr (should-error (roost-search-open) :type 'user-error))))
                   (should (equal (buffer-string) shown))))
               (should (string-match-p "Fresh CSV" (thing-at-point 'line)))
               ;; Later lists redraw it too, so statuses stay current.
               (roost--apply-snapshot "dev" (list (roost-test--task)
                                                  (append '((name . "fresh task"))
                                                          (roost-test--task "1111111111111111" "ready"))))
               (roost--redraw)
               (should (string-match-p "^fresh task  dev · shop  ready$" (buffer-string)))
               ;; A live task's message opens the task, and task commands act on it.
               (roost-search-next)
               (should (string-match-p "Quote CSV" (thing-at-point 'line)))
               ;; Showing a whole message keeps point on it, wherever it is.
               (roost-search-toggle)
               (should (string-match-p "Quote CSV" (thing-at-point 'line)))
               (should (string-match-p "commas, please\\.\n" (buffer-string)))
               ;; It wraps to the window, also once the window is resized.
               (should (memq #'roost--search-resized window-size-change-functions))
               (cl-letf (((symbol-function 'roost--usable-width) (lambda (&rest _) 28)))
                 (roost--search-resized (selected-window))
                 ;; Within its indentation of 8 columns.
                 (should (string-match-p "^Quote CSV fields\nwith commas, please\\.$" (buffer-string))))
               (roost--render-search)
               (roost-search-toggle)
               (should (string-match-p "Quote CSV" (thing-at-point 'line)))
               (should (equal (roost--key (roost--task-at-point)) '("dev" "0123456789abcdef")))
               (roost-search-open)
               (should (equal (roost--key opened) '("dev" "0123456789abcdef")))
               (roost-search-previous 2)
               (should (string-match-p "Import CSV" (thing-at-point 'line)))
               (should-error (roost-search-previous) :type 'user-error)
               ;; A task Roost had when the reply came, and whose host's next
               ;; list lacks it, has been retired since too.
               (roost--apply-snapshot "dev" (list (append '((name . "fresh task"))
                                                          (roost-test--task "1111111111111111" "ready"))))
               (roost--redraw)
               (should (string-match-p "^fix auth  dev · shop  past task$" (buffer-string)))
               ;; Searching again ignores replies to the search before.
               (roost-search-again)
               (funcall (nth 3 dev) '((tasks) (moreTasks . 0)))
               (should (string-match-p "Searching dev, box…" (buffer-string)))))
         (when (get-buffer roost--search-buffer) (kill-buffer roost--search-buffer)))))
   (should-error (roost-search " ") :type 'user-error)
   (should (eq (lookup-key roost-dashboard-mode-map "/") 'roost-search))
   (should (eq (lookup-key roost-sidebar-list-mode-map "/") 'roost-search))
   (should (eq (lookup-key roost-task-info-mode-map "/") 'roost-search))))

(ert-deftest roost-search-fits-a-long-message-to-its-window ()
  ;; A long message ran past the window's edge; cut to fit, it opens up.
  (roost-test--isolated
   (let ((roost-hosts '("dev")) requests
         (long (mapconcat #'identity (make-list 30 "needle in the haystack") " ")))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (host _action _params success &optional _failure) (push (list host success) requests)))
               ((symbol-function 'roost--refresh-host) #'ignore))
       (save-window-excursion
         (unwind-protect
             (progn
               (roost-search "needle")
               (set-buffer roost--search-buffer)
               (switch-to-buffer (current-buffer))
               (funcall (cadr (car requests))
                        `((tasks ((past . t) (key . "0a1b/hay-9f8e7d") (name . "hay") (repo)
                                  (hits ((at . "2026-10-03T10:00:00Z") (role . "user") (session . "s1") (line . 1)
                                         (snippet . ,long) (text . ,long)))
                                  (more . 0)))
                          (moreTasks . 0)))
               (goto-char (point-min))
               (search-forward "haystack")
               (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
                 (should (string-suffix-p "…" line))
                 (should (<= (string-width line) (window-body-width))))
               (should-not (roost--search-whole-p))
               (roost-search-toggle)
               (should (string-match-p (concat (regexp-quote "haystack needle") ".*\n.*haystack")
                                       (buffer-string)))
               (roost-search-toggle)
               ;; Opened in a narrow window, a short message shows in full
               ;; below its cut line; widened, its line shows it whole, once.
               (let ((short "needle and thread") (saved roost--search-replies))
                 (setq roost--search-replies
                       `(("dev" (tasks ((past . t) (key . "0a1b/short-1a2b3c") (name . "short") (repo)
                                        (hits ((at . "2026-10-04T10:00:00Z") (role . "user") (session . "s2")
                                               (line . 1) (snippet . ,short) (text . ,short)))
                                        (more . 0)))
                          (moreTasks . 0))))
                 (cl-letf (((symbol-function 'roost--usable-width) (lambda (&rest _) 30)))
                   (roost--render-search)
                   (goto-char (point-min))
                   (search-forward "2026-10-04")
                   (roost-search-toggle)
                   (should (string-match-p "needle and thread\n" (buffer-string))))
                 (roost--render-search)
                 (should (= (how-many "needle and thread" (point-min) (point-max)) 1))
                 (setq roost--search-replies saved roost--search-expanded nil))
               ;; Shown in two windows, the narrower decides; in one narrower
               ;; than a result's date and speaker, the whole line is cut.
               (dolist (columns '(40 20))
                 (delete-other-windows)
                 (let ((narrow (split-window nil (- (window-total-width) columns 1) 'right)))
                   (set-window-buffer narrow (current-buffer))
                   (roost--render-search)
                   (goto-char (point-min))
                   (search-forward "2026-10-03")
                   (should (<= (string-width (buffer-substring (line-beginning-position) (line-end-position)))
                               (roost--usable-width narrow)))
                   (should (get-text-property (line-beginning-position) 'roost-search-cut)))))
           (when (get-buffer roost--search-buffer) (kill-buffer roost--search-buffer))))))))

(ert-deftest roost-search-shows-a-task-retired-after-its-reply-as-past ()
  (roost-test--isolated
   (let ((roost-hosts '("dev")) requests fetched)
     (roost--cache-task "dev" (roost-test--task))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (host _action _params success _failure) (push (list host success) requests)))
               ((symbol-function 'roost--refresh-host) (lambda (host &rest _) (push host fetched))))
       (unwind-protect
           (save-window-excursion
             (roost-search "csv")
             (set-buffer roost--search-buffer)
             (funcall (nth 1 (car requests))
                      '((tasks ((id . "0123456789abcdef") (name . "fix auth") (repo . "/home/user/shop")
                                (hits ((at . "2026-10-01T10:01:00Z") (role . "user") (session . "s1") (line . 1)
                                       (snippet . "Quote CSV") (text . "Quote CSV")))
                                (more . 0)))
                        (moreTasks . 0)))
             ;; Roost had the task, so nothing was fetched.
             (should-not fetched)
             (should (string-match-p "^fix auth  dev · shop  ready$" (buffer-string)))
             ;; A list asked for before the reply may predate the task.
             (roost--apply-snapshot "dev" nil (gethash "dev" roost--list-requests 0))
             (roost--redraw)
             (should (string-match-p "^fix auth  dev · shop$" (buffer-string)))
             ;; One asked for after it lacks the task: retired since.
             (roost--apply-snapshot "dev" nil)
             (roost--redraw)
             (should (string-match-p "^fix auth  dev · shop  past task$" (buffer-string))))
         (when (get-buffer roost--search-buffer) (kill-buffer roost--search-buffer)))))))

(ert-deftest roost-search-says-no-message-only-of-hosts-it-searched ()
  (roost-test--isolated
   (let ((roost-hosts '("dev" "box" nil)) requests)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (host _action _params success failure) (push (list host success failure) requests))))
       (unwind-protect
           (save-window-excursion
             (roost-search "zebra")
             (set-buffer roost--search-buffer)
             (funcall (nth 2 (assoc "dev" requests)) "ssh: no route")
             (funcall (nth 1 (assoc "box" requests)) '((tasks) (moreTasks . 0) (incomplete . t)))
             (funcall (nth 1 (assoc nil requests)) '((tasks) (moreTasks . 0) (incomplete)))
             (should (string-match-p "^No message in your tasks' conversations on box, local contains every word\\.$"
                                     (buffer-string)))
             ;; A host that ran out of time says so.
             (should (string-match-p "^box ran out of time; it searched its newest conversations only$"
                                     (buffer-string)))
             (should-not (string-match-p "^local ran out" (buffer-string)))
             ;; A host added meanwhile was not asked, so it is not awaited.
             (setq roost-hosts (cons "new" roost-hosts))
             (roost--render-search)
             (should-not (string-match-p "Searching" (buffer-string)))
             ;; With every host failing, nothing was searched.
             (setq requests nil)
             (roost-search-again)
             (dolist (request requests) (funcall (nth 2 request) "down"))
             (should (string-match-p "^Could not search local: down$" (buffer-string)))
             (should-not (string-match-p "No message" (buffer-string)))
             ;; With every host searched, no host need be named.
             (setq requests nil)
             (roost-search-again)
             (dolist (request requests) (funcall (nth 1 request) '((tasks) (moreTasks . 0))))
             (should (string-match-p "^No message in your tasks' conversations contains every word\\.$"
                                     (buffer-string))))
         (when (get-buffer roost--search-buffer) (kill-buffer roost--search-buffer)))))))

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
         ;; The current task is marked to the window's edge; statuses are
         ;; right-aligned.
         (should (member " ● budget-alerts    permission" lines))
         (should (= (string-width " ● budget-alerts    permission") roost-sidebar-width))
         (goto-char (roost--task-row '("dev" "1111111111111111")))
         (should (memq 'roost-current (ensure-list (get-text-property (point) 'face))))
         (should (memq 'roost-current (ensure-list (get-text-property (line-end-position) 'face))))
         (should (eq (face-attribute 'roost-current :extend) t))
         (forward-line)
         (should-not (memq 'roost-current (ensure-list (get-text-property (point) 'face))))
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

(ert-deftest roost-a-draft-on-a-host-not-connected-to-takes-a-known-project ()
  ;; Composing in a remote directory looked for its checkout there, which
  ;; held Emacs while TRAMP connected, for a project Roost already knew.
  (roost-test--isolated
   (let ((roost--remembered-projects '("/ssh:dev:/srv/ledger/" "/ssh:dev:/srv/ledger/tools/"
                                       "/ssh:alice@dev:/srv/ledger/"))
         (roost--projects-loaded t)
         looked)
     (cl-letf (((symbol-function 'locate-dominating-file) (lambda (&rest _) (setq looked t) nil))
               ((symbol-function 'vc-root-dir) (lambda (&rest _) (setq looked t) nil)))
       (with-temp-buffer
         (setq default-directory "/ssh:dev:/srv/ledger/src/")
         (should (equal (roost--compose-default-directory nil nil) "/ssh:dev:/srv/ledger/"))
         ;; The deepest project it is in.
         (setq default-directory "/ssh:dev:/srv/ledger/tools/bin/")
         (should (equal (roost--compose-default-directory nil nil) "/ssh:dev:/srv/ledger/tools/"))
         ;; Whatever TRAMP method names it.
         (setq default-directory "/scp:dev:/srv/ledger/tools/bin/")
         (should (equal (roost--compose-default-directory nil nil) "/ssh:dev:/srv/ledger/tools/"))
         ;; Not the same path on another host, or as another user.
         (setq default-directory "/ssh:other:/srv/ledger/src/")
         (should-not (roost--known-project-of default-directory))
         (setq default-directory "/ssh:bob@dev:/srv/ledger/src/")
         (should-not (roost--known-project-of default-directory))
         (setq default-directory "/scp:alice@dev:/srv/ledger/src/")
         (should (equal (roost--known-project-of default-directory) "/ssh:alice@dev:/srv/ledger/"))
         ;; Outside them, on a host not connected to, the latest project.
         (setq default-directory "/ssh:dev:/tmp/")
         (should (equal (roost--compose-default-directory nil nil) "/ssh:dev:/srv/ledger/"))
         (should-not looked)
         ;; A local directory is looked in.
         (setq default-directory temporary-file-directory)
         (roost--compose-default-directory nil nil)
         (should looked))))))

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
               (should (< (string-search "Changes" (buffer-string))
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
  (let* ((files '(((path . "notes.py") (added . 10) (deleted . 3) (uncommitted . t))
                  ((path . "docs/a/very/long/path/to/the/guide.md") (added . 1) (deleted . 0))
                  ((path . "logo.png"))
                  ((path . "notes.md") (untracked . t))))
         (task (append `((files . ,files)) (roost-test--task)))
         shown)
    (with-temp-buffer
      (roost--insert-changed-files task 40)
      (let ((lines (split-string (buffer-string) "\n" t)))
        ;; Files with changes not yet committed, new ones too, come first.
        (should (equal (seq-take lines 4) '("  Uncommitted" "  notes.py  +10 −3" "  notes.md  new"
                                            "  Committed")))
        (should (member "  logo.png  binary" lines))
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
       (let ((merged (roost--cache-task "dev" (append '((ahead . 0) (dirty)) (roost-test--task nil "ready"))))
             question)
         (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt &rest _) (setq question prompt) t)))
           (roost-retire merged))
         (should (string-match-p "Nothing in them would be lost" question)))
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
     ;; The menu, away from the panel's buttons, names the key that shows them.
     (should-not (string-match-p "shows it" (roost--next-step task)))
     (should (string-suffix-p "or remove it; i shows it" (roost--next-step task t)))
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

(ert-deftest roost-doctor-says-whether-roost-watches-from-startup ()
  (let ((roost-watch-mode nil) (roost--watching-on-demand nil))
    (should (eq (nth 1 (assoc "Watching" (roost--doctor-local-checks))) 'optional)))
  ;; Opening the dashboard watched only from then on.
  (let ((roost-watch-mode t) (roost--watching-on-demand t))
    (should (string-match-p "(roost-watch-mode 1)" (nth 3 (assoc "Watching" (roost--doctor-local-checks))))))
  (let ((roost-watch-mode t) (roost--watching-on-demand nil))
    (should (eq (nth 1 (assoc "Watching" (roost--doctor-local-checks))) t))))

(ert-deftest roost-c-c-?-opens-the-menu-in-agents-terminals ()
  ;; Every other key in an agent's terminal goes to the agent.
  (roost-test--isolated
   (roost--cache-task "dev" (roost-test--task))
   (roost-test--with-tmux-buffers
    (let ((roost-watch-mode t))
      (with-temp-buffer
        (setq major-mode 'tmux-control-mode)
        (setq-local roost-test--tmux '(:host "dev" :socket "main" :session "roost-123456" :pane "%3"))
        (should (eq (key-binding (kbd "C-c ?")) #'roost-dispatch))
        ;; Not in the terminal of a tmux session of your own, nor elsewhere.
        (setq-local roost-test--tmux '(:host "dev" :socket "main" :session "work" :pane "%3"))
        (use-local-map (define-keymap "C-c ?" #'ignore))
        (should (eq (key-binding (kbd "C-c ?")) #'ignore))
        (setq major-mode 'fundamental-mode)
        (should (eq (key-binding (kbd "C-c ?")) #'ignore))))))
  (should (eq (keymap-lookup roost-magit-mode-map "C-c ?") #'roost-dispatch)))

(ert-deftest roost-watching-turned-on-by-your-configuration-is-from-the-start ()
  ;; The sidebar turned on in your configuration watches from the start;
  ;; opening it later, like the dashboard or M-x roost-watch-mode, only
  ;; from then on, and the setup check suggests more.
  (let ((roost-watch-mode nil) (roost--watching-on-demand nil) (roost--watch-timer nil)
        (roost-sidebar-mode nil) (global-mode-string nil) (roost-watch-interval 3600))
    (cl-letf (((symbol-function 'roost--magit-setup) #'ignore)
              ((symbol-function 'roost--watch-layout) #'ignore)
              ((symbol-function 'roost--sync-all-frames) #'ignore)
              ((symbol-function 'roost-refresh) #'ignore))
      (unwind-protect
          (progn
            (let ((after-init-time nil))
              (roost-sidebar-mode 1))
            (should roost-watch-mode)
            (should-not roost--watching-on-demand)
            ;; Turning it on again changes nothing.
            (roost-watch-mode 1)
            (should-not roost--watching-on-demand)
            (roost-watch-mode -1)
            (roost-watch-mode 1)
            (should roost--watching-on-demand)
            (roost-watch-mode -1)
            (setq roost-sidebar-mode nil)
            (roost-sidebar-mode 1)
            (should roost--watching-on-demand))
        (roost-watch-mode -1)))))

(ert-deftest roost-a-finished-tasks-panel-closes-with-it ()
  ;; It stayed, saying the task was retired, and kept the panel of the
  ;; next task from docking beside its terminal.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task)))
         (other (roost--cache-task "dev" (roost-test--task "1111111111111111"))))
     (cl-letf (((symbol-function 'roost--refresh-host) #'ignore))
       (save-window-excursion
         (delete-other-windows)
         (let ((kept (roost--task-info-buffer other)))
           (roost-task-info task)
           (let ((panel (window-buffer (selected-window))))
             (should (= (count-windows) 2))
             (roost--retired-workspace task)
             (should-not (buffer-live-p panel))
             (should (= (count-windows) 1))
             (should (buffer-live-p kept))
             (kill-buffer kept))))
       ;; A panel no window shows goes too.
       (let ((hidden (roost--task-info-buffer other)))
         (roost--retired-workspace other)
         (should-not (buffer-live-p hidden)))))))

(ert-deftest roost-reading-a-tasks-panel-sees-its-agent ()
  ;; Reading the reply in the panel left the task waiting, and n went back to it.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "ready"))))
     (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) t)))
       (save-window-excursion
         (switch-to-buffer (roost--task-info-buffer task))
         (unwind-protect
             (progn
               (should (equal (roost--key (roost--watched-task)) (roost--key task)))
               (roost--note-watched-agent)
               (should-not (roost--waiting-p (gethash (roost--key task) roost--tasks))))
           (kill-buffer)))))))

(defun roost-test--task-menu-suffixes ()
  "The commands of `roost-dispatch's task group, with their :inapt-if.
Read from the layout transient keeps, whose form varies by version."
  (let (found)
    (cl-labels ((walk (node in-task)
                  (when-let* ((items (cond ((vectorp node) (append node nil))
                                           ((proper-list-p node) node))))
                    (if (and in-task (memq :command items))
                        (push (cons (cadr (memq :command items)) (cadr (memq :inapt-if items))) found)
                      (let ((task (or in-task
                                      (seq-some (lambda (item)
                                                  (and (proper-list-p item) (keywordp (car item))
                                                       (eq (plist-get item :description)
                                                           'roost--dispatch-task-description)))
                                                items))))
                        (dolist (item items) (walk item task)))))))
      (walk (get 'roost-dispatch 'transient--layout) nil))
    (nreverse found)))

(ert-deftest roost-a-task-offers-what-it-can-do-now ()
  ;; A stopped task's panel offered Stop, Shell and Send, which its host refuses.
  (roost-test--isolated
   (let* ((commands '(("RET" . roost-open-task) ("t" . roost-shell) ("f" . roost-files)
                      ("e" . roost-send) ("r" . roost-review) ("D" . roost-diff) ("u" . roost-update)
                      ("P" . roost-pr) ("m" . roost-merge-retire) ("x" . roost-retire)
                      ("X" . roost-forget) ("K" . roost-stop) ("s" . roost-resume)))
          (applies (lambda (task)
                     (mapcar #'car (seq-filter (lambda (command) (roost--action-applies-p task (cdr command)))
                                               commands))))
          (stopped (roost--cache-task "dev" (append '((live)) (roost-test--task nil "stopped"))))
          (working (roost--cache-task "dev" (append '((live . t) (ahead . 0) (dirty))
                                                    (roost-test--task "1111111111111111" "running"))))
          (finished (roost--cache-task "dev" (append '((live . t) (ahead . 2))
                                                     (roost-test--task "2222222222222222" "ready"))))
          (merged (roost--cache-task "dev" (append '((live . t) (ahead . 2) (prStatus (state . "MERGED"))
                                                     (pr (number . 12) (url . "https://github.com/o/r/pull/12")))
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
         (should-not (roost--resume-inapt-p))))
     ;; Every task entry of the menu has its predicate.
     (let ((suffixes (roost-test--task-menu-suffixes)))
       (should (assq 'roost-goto-note suffixes))
       (should (seq-every-p (lambda (command) (assq (cdr command) suffixes)) commands))
       (dolist (suffix suffixes)
         (should (functionp (cdr suffix))))))))

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
       (should-not (memq 'roost-current (ensure-list (get-text-property 0 'face (roost--sidebar-row a 30)))))
       (should (memq 'roost-current (ensure-list (get-text-property 0 'face (roost--sidebar-row b 30)))))))))

(ert-deftest roost-tasks-of-one-name-show-their-ids ()
  (roost-test--isolated
   (let* ((a (roost--cache-task "dev" (roost-test--task)))
          (b (roost--cache-task "dev" (roost-test--task "1111111111111111")))
          (elsewhere (roost--cache-task "ci" (roost-test--task "2222222222222222")))
          (alone (roost--cache-task "dev" (append '((name . "tidy notes"))
                                                  (roost-test--task "3333333333333333"))))
          (layout (roost--dashboard-layout (roost-tasks) 120)))
     (should (string-match-p "fix auth 012345" (roost--sidebar-row a 30)))
     (should (string-match-p "fix auth 111111" (roost--sidebar-row b 30)))
     (let ((row (roost--dashboard-row b layout 120)))
       (should (string-match "fix auth \\(111111\\)" row))
       (should (eq (get-text-property (match-beginning 1) 'face row) 'roost-dim)))
     ;; On another host, or with a name of its own, a task shows its name alone.
     (should-not (string-match-p "222222" (roost--sidebar-row elsewhere 30)))
     (should-not (string-match-p "333333" (roost--dashboard-row alone layout 120)))
     ;; A name cut to fit keeps the ID.
     (should (equal (substring-no-properties (roost--row-name a 9)) "f… 012345")))))

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
         (save-window-excursion
           (with-current-buffer buffer
             (roost-task-info-mode) (setq roost--buffer-task-key (roost--key task))
             (roost--render-task-info) (should (eq (roost--task-at-point) task)))
           (set-window-buffer (selected-window) buffer)
           (setf (alist-get 'status task) "stopped")
           (roost--redraw) (should (eq original (current-buffer)))
           (with-current-buffer buffer
             (should (string-match-p "stopped" (buffer-string))))
           (remhash (roost--key task) roost--tasks) (roost--redraw)
           (with-current-buffer buffer (should-error (roost--task-at-point) :type 'user-error)))
       (kill-buffer buffer)))))

(ert-deftest roost-redraws-keep-the-selection-and-wait-for-hidden-panels ()
  ;; Each poll's redraw moved the mark to the top of the panel, so copying
  ;; part of the agent's reply copied the panel's heading with it.
  (roost-test--isolated
   (let ((task (roost--cache-task nil (append '((lastMessage . "Fixed the login bug.")) (roost-test--task))))
         (buffer (get-buffer-create " *roost-test-info*")))
     (unwind-protect
         (save-window-excursion
           (with-current-buffer buffer
             (roost-task-info-mode) (setq roost--buffer-task-key (roost--key task))
             (roost--render-task-info))
           (set-window-buffer (selected-window) buffer)
           (with-current-buffer buffer
             (goto-char (point-min)) (search-forward "Fixed ")
             (push-mark (point) t t) (forward-word 2)
             (should (equal (buffer-substring-no-properties (region-beginning) (region-end)) "the login")))
           (roost--redraw)
           (with-current-buffer buffer
             (should (equal (buffer-substring-no-properties (region-beginning) (region-end)) "the login")))
           ;; A panel no window shows is redrawn once one does.
           (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
           (setf (alist-get 'status task) "stopped")
           (roost--redraw)
           (with-current-buffer buffer
             (should-not (string-match-p "stopped" (buffer-string)))
             (should (memq #'roost--shown window-buffer-change-functions)))
           (set-window-buffer (selected-window) buffer)
           (roost--shown (selected-window))
           (with-current-buffer buffer
             (should (string-match-p "stopped" (buffer-string)))))
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

(ert-deftest roost-next-attention-takes-blocked-tasks-in-turn ()
  ;; With three asking, n went back and forth between the first two.
  (roost-test--isolated
   (dolist (host '("a" "b" "c"))
     (roost--cache-task host (roost-test--task nil "permission")))
   (roost--cache-task "d" (roost-test--task))
   (let (opened)
     (cl-letf (((symbol-function 'roost-open-task)
                (lambda (task) (setq opened (roost--key task) roost--current-task opened))))
       (should (equal (cl-loop repeat 4 do (roost-next-waiting) collect (car opened))
                      '("a" "b" "c" "a")))))))

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

;; Canvases come with Emacs 32, so these tests stand in for them.
(defmacro roost-test--with-canvases (on &rest body)
  "Run BODY with Roost's status lights moving while ON, on stand-in canvases.
`roost-test--refreshed' counts the canvases redrawn."
  (declare (indent 1))
  `(let ((roost--lights (make-hash-table :test 'equal))
         (roost--lights-timer nil)
         (roost-test--refreshed 0))
     (cl-letf (((symbol-function 'roost--animations-p) (lambda () ,on))
               ((symbol-function 'create-image)
                (lambda (data _type _data-p &rest props)
                  ;; Scaled, Emacs would draw only part of a canvas.
                  (should (eql (plist-get props :scale) 1))
                  `(image :type canvas :data ,data ,@props)))
               ((symbol-function 'canvas-refresh) (lambda (&rest _) (cl-incf roost-test--refreshed)))
               ((symbol-function 'frame-focus-state) (lambda (&rest _) t))
               ((symbol-function 'mode-line-window-selected-p) (lambda () roost-test--selected))
               ;; Batch Emacs has only a text frame; tests say what it stands for.
               ((symbol-function 'roost--light-frame-p) (lambda (_frame) roost-test--graphic)))
       (unwind-protect (progn ,@body)
         (when (timerp roost--lights-timer) (cancel-timer roost--lights-timer))))))

(defvar roost-test--refreshed 0)
(defvar roost-test--selected t)
(defvar roost-test--graphic t)

(ert-deftest roost-status-lights-stay-dots-without-canvases ()
  ;; Off, or with no frame that shows canvases, a task's light is its dot.
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task nil "running")))
         (roost--lights (make-hash-table :test 'equal))
         (roost--lights-timer nil))
     (cl-letf (((symbol-function 'roost--light-frame-p) #'ignore))
       (dolist (roost-animations '(nil t))
         (with-temp-buffer
           (let ((dot (roost--status-light task 'sidebar)))
             (should (equal dot "●"))
             (should (eq (get-text-property 0 'face dot) 'roost-status-running))
             (should-not (get-text-property 0 'display dot)))
           (roost--light-margins)
           (should (= left-margin-width 0)))))
     (should (zerop (hash-table-count roost--lights)))
     (should-not roost--lights-timer))))

(ert-deftest roost-status-lights-move-only-while-an-agent-waits ()
  ;; Motion means an agent needs you, as it counts in the mode line: one
  ;; at work rests, and so does one you have seen since it stopped.
  (roost-test--isolated
   (let ((motion (lambda (status &optional seen)
                   (let ((task (roost--cache-task "dev" (roost-test--task nil status))))
                     (when seen (puthash (roost--key task) (roost--field task 'updatedAt) roost--seen))
                     (prog1 (roost--light-motion task)
                       (remhash (roost--key task) roost--seen))))))
     (should (eq (funcall motion "permission") 'pulse))
     (dolist (status '("ready" "interrupted" "error" "failed" "crashed" "exited"))
       (should (eq (funcall motion status) 'glow))
       (should-not (funcall motion status t)))
     (dolist (status '("running" "stopped"))
       (should-not (funcall motion status)))))
  (roost-test--with-canvases t
    (let* ((width 6) (height 8)
           (pixels-at (lambda (motion phase)
                        (let ((light (list :image (create-image (make-vector (* width height) 0) 'canvas t
                                                                :data-width width :data-height height
                                                                :scale 1)
                                           :motion motion :color #xFFAA66FF :background #xFF1E1E1E)))
                          (roost--light-draw light phase)
                          (plist-get (cdr (plist-get light :image)) :data)))))
      ;; Canvases have no transparency, so a light paints its background.
      (let ((still (funcall pixels-at nil 0.0)))
        (should (= (aref still 0) #xFF1E1E1E))
        (should (= (aref still (+ (/ width 2) (* (/ height 2) width))) #xFFAA66FF))
        (should (equal still (funcall pixels-at nil 0.5))))
      (dolist (motion '(pulse glow))
        (should-not (equal (funcall pixels-at motion 0.0) (funcall pixels-at motion 0.5))))
      (should (= roost-test--refreshed 6)))))

(ert-deftest roost-status-lights-paint-the-background-that-shows ()
  ;; A theme can leave the margin face of Emacs 31 and later without a
  ;; background, or anything to inherit one from, as modus-themes does with
  ;; an unspecified fringe: the margin shows the default background, where
  ;; lights painted mid-gray squares.
  (roost-test--isolated
   (roost-test--with-canvases t
     (let ((task (roost--cache-task "dev" (roost-test--task "1111111111111111" "permission")))
           (default (face-background 'default))
           (foreground (face-foreground 'default))
           (inherit (and (facep 'margin) (face-attribute 'margin :inherit))))
       (unwind-protect
           (with-temp-buffer
             (set-face-background 'default "#123456")
             (when (facep 'margin) (set-face-attribute 'margin nil :inherit 'unspecified))
             (roost--status-light task 'sidebar)
             (should (= (plist-get (gethash (cons 'sidebar (roost--key task)) roost--lights) :background)
                        (roost--light-pixel "#123456")))
             ;; A running agent's light is in the text's colour, not mid-gray.
             (set-face-foreground 'default "#ABCDEF")
             (let ((running (roost--cache-task "dev" (roost-test--task "2222222222222222" "running"))))
               (roost--status-light running 'sidebar)
               (should (= (plist-get (gethash (cons 'sidebar (roost--key running)) roost--lights) :color)
                          (roost--light-pixel "#ABCDEF")))))
         (set-face-foreground 'default foreground)
         (set-face-background 'default default)
         (when (facep 'margin) (set-face-attribute 'margin nil :inherit inherit)))))))

(ert-deftest roost-status-lights-move-until-their-agents-rest ()
  (roost-test--isolated
   (let ((on t))
     (roost-test--with-canvases on
       (let ((asking (roost--cache-task "dev" (roost-test--task "1111111111111111" "permission")))
             (running (roost--cache-task "dev" (roost-test--task "2222222222222222" "running"))))
         (with-temp-buffer
           ;; At work, a light rests: nothing has to move.
           (roost--status-light running 'sidebar)
           (should-not roost--lights-timer)
           ;; The light shows in the margin, taking no column of the text.
           (let ((light (roost--status-light asking 'sidebar)))
             (should (equal (substring-no-properties light) "●"))
             (should (equal (car (get-text-property 0 'display light)) '(margin left-margin))))
           ;; In the task panel, it takes the dot's place, painting the
           ;; highlight behind it while it is on the highlighted line.
           (should (eq (car (get-text-property 0 'display (roost--status-light asking '(panel . 1) t))) 'image))
           (let ((light (gethash (cons '(panel . 1) (roost--key asking)) roost--lights)))
             (cl-letf (((symbol-function 'face-background)
                        (lambda (face &rest _) (if (eq face 'roost-selection) "#ffffff" "#000000"))))
               (save-window-excursion
                 (set-window-buffer nil (current-buffer))
                 (insert "fix auth  " (roost--status-light asking '(panel . 1) t) " permission\nmore\n")
                 (set-window-point nil (point-min))
                 (roost--mark-selection)
                 ;; Batch Emacs has a terminal's colors, so compare its own pixels.
                 (should-not (= (roost--light-pixel "#ffffff") (roost--light-pixel "#000000")))
                 (should (= (plist-get light :background) (roost--light-pixel "#ffffff")))
                 (set-window-point nil (point-max))
                 (roost--mark-selection)
                 (should (= (plist-get light :background) (roost--light-pixel "#000000")))
                 (erase-buffer))))
           (should (= (hash-table-count roost--lights) 3))
           (should (timerp roost--lights-timer))
           ;; Asked for again unchanged, a light isn't redrawn.
           (let ((before roost-test--refreshed))
             (roost--status-light running 'sidebar)
             (should (= roost-test--refreshed before)))
           ;; The mode line has one too, for the agents waiting, in the
           ;; selected window, whose background it paints.
           (should (eq (car (get-text-property 0 'display (roost--mode-line-count))) 'image))
           (let ((roost-test--selected nil))
             (should-not (get-text-property 0 'display (roost--mode-line-count))))
           ;; Comparing counts makes no light, and watching no more drops it.
           (remhash '(mode-line . waiting) roost--lights)
           (should-not (get-text-property 0 'display (roost--mode-line-count t)))
           (should-not (gethash '(mode-line . waiting) roost--lights))
           (roost--mode-line-count)
           (let ((roost-watch-interval 3600))
             (roost-watch-mode -1))
           (should-not (gethash '(mode-line . waiting) roost--lights))
           (roost--mode-line-count)
           ;; Lights of tasks no longer listed are forgotten, only at their place.
           (roost--lights-forget 'sidebar (list (roost--key asking)))
           (should (= (hash-table-count roost--lights) 3))
           (should-not (gethash (cons 'sidebar (roost--key running)) roost--lights))
           (roost--status-light running '(panel . 2) t)
           (roost--lights-forget '(panel . 2) nil)
           (should (= (hash-table-count roost--lights) 3))
           ;; The tick redraws a moving light that shows and whose motion moved on:
           ;; the mode line's, not those of a buffer in no window.
           (maphash (lambda (_id light) (plist-put light :phase -1.0)) roost--lights)
           (let ((before roost-test--refreshed))
             (roost--lights-tick)
             (should (= roost-test--refreshed (1+ before))))
           (save-window-excursion
             (set-window-buffer nil (current-buffer))
             ;; In a graphical window its lights move too; in a text frame's,
             ;; which shows the dots, they don't, nor does its mode line get one.
             (maphash (lambda (_id light) (plist-put light :phase -1.0)) roost--lights)
             (let ((before roost-test--refreshed))
               (roost--lights-tick)
               (should (= roost-test--refreshed (+ before 3))))
             (let ((roost-test--graphic nil))
               (maphash (lambda (_id light) (plist-put light :phase -1.0)) roost--lights)
               (let ((before roost-test--refreshed))
                 (roost--lights-tick)
                 (should (= roost-test--refreshed (1+ before))))
               (should-not (get-text-property 0 'display (roost--mode-line-count)))
               ;; The lights get a margin, which goes when they are turned
               ;; off; a text frame's window keeps its own.
               (roost--light-margins)
               (should (= left-margin-width 2))
               (should-not (car (window-margins)))
               ;; A text frame's window that shows the buffer later, taking
               ;; its 2 columns, gets its own back as it starts showing it.
               (should (memq #'roost--light-margins-shown window-buffer-change-functions))
               (set-window-margins nil 2)
               (roost--light-margins-shown (selected-window))
               (should-not (car (window-margins)))
               ;; Run for a window that went on to show another buffer, it
               ;; leaves that one alone.
               (let ((lights (current-buffer)))
                 (with-temp-buffer
                   (set-window-buffer nil (current-buffer))
                   (with-current-buffer lights (roost--light-margins-shown (selected-window)))
                   (should-not (local-variable-p 'roost--light-margin))
                   (should-not (memq #'roost--light-margins-shown window-buffer-change-functions)))
                 (set-window-buffer nil lights))
               (setq on nil)
               (roost--light-margins)
               (should (= left-margin-width 0))
               (should-not (memq #'roost--light-margins-shown window-buffer-change-functions))
               (setq on t)))
           ;; A sidebar row whose light is in the margin has the dot's column
           ;; for its name: 31 characters, one of them not shown.
           (should (= (string-width (roost--sidebar-row asking 30 t)) 31))
           (should (= (string-width (roost--sidebar-row asking 30)) 30)))
         ;; A margin the buffer had is kept, and there again after.
         (with-temp-buffer
           (setq left-margin-width 3)
           (roost--light-margins)
           (should (= left-margin-width 3))
           (setq on nil)
           (roost--light-margins)
           (should (= left-margin-width 3))
           (setq left-margin-width 1)
           (roost--light-margins)
           (should (= left-margin-width 1))
           ;; No margin at all, said with nil, comes back as nil.
           (setq left-margin-width nil on t)
           (roost--light-margins)
           (should (= left-margin-width 2))
           (setq on nil)
           (roost--light-margins)
           (should-not left-margin-width)
           (setq on t))
         ;; A mode line that shows the light asks for it whenever polls
         ;; make mode lines redraw; one nobody asks for goes.
         (roost--mode-line-count)
         (roost--mode-line-light-check)
         (should (gethash '(mode-line . waiting) roost--lights))
         (plist-put (gethash '(mode-line . waiting) roost--lights) :asked (- (float-time) 3600))
         (roost--mode-line-light-check)
         (should-not (gethash '(mode-line . waiting) roost--lights))
         ;; The lights of a buffer that is gone go whenever lights are
         ;; forgotten, moving or not.
         (let ((buffer (generate-new-buffer " lights")))
           (with-current-buffer buffer (roost--status-light running 'sidebar))
           (kill-buffer buffer)
           (roost--lights-forget 'dashboard nil)
           (should-not (gethash (cons 'sidebar (roost--key running)) roost--lights)))
         ;; Once nobody waits, the mode line's light goes.
         (roost--cache-task "dev" (roost-test--task "1111111111111111" "running"))
         (should-not (roost--mode-line-count))
         (should-not (gethash '(mode-line . waiting) roost--lights))
         ;; The buffer is gone, and so are its lights at the next tick; once
         ;; nothing moves, neither does the timer.
         (roost--lights-tick)
         (should (zerop (hash-table-count roost--lights)))
         (should-not roost--lights-timer)
         ;; A light moving in a buffer no window shows doesn't keep it going
         ;; either; drawing that buffer again starts it.
         (with-temp-buffer
           (roost--cache-task "dev" (roost-test--task "1111111111111111" "permission"))
           (roost--status-light (roost--cache-task "dev" (roost-test--task "1111111111111111" "permission"))
                                '(panel . 1) t)
           (should (timerp roost--lights-timer))
           (roost--lights-tick)
           (should-not roost--lights-timer)
           (roost--status-light (roost--cache-task "dev" (roost-test--task "1111111111111111" "permission"))
                                '(panel . 1) t)
           (should (timerp roost--lights-timer))))))))

(ert-deftest roost-status-lights-wake-emacs-only-when-they-move ()
  ;; A timer twelve times a second cost a redisplay each time, even
  ;; with Emacs in the background, where the lights don't move.
  (roost-test--isolated
   (roost-test--with-canvases t
     (let ((task (roost--cache-task "dev" (roost-test--task "1111111111111111" "permission")))
           (focused t))
       (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) focused)))
         (cl-flet ((wait () (- (float-time (timer--time roost--lights-timer)) (float-time))))
           (with-temp-buffer
             (save-window-excursion
               (set-window-buffer nil (current-buffer))
               (roost--status-light task 'sidebar)
               ;; A pulse moves sixteen steps in 1.6 seconds: the next is
               ;; at most a tenth of a second away.
               (roost--lights-tick)
               (should (< (wait) 0.11))
               ;; In the background, it looks again a second later.
               (setq focused nil)
               (roost--lights-tick)
               (should (> (wait) 0.9))
               (setq focused t)
               (roost--lights-tick)
               (should (< (wait) 0.11))))))))))

(ert-deftest roost-status-lights-follow-the-option-at-once ()
  (roost-test--isolated
   (roost-test--with-canvases t
     (let ((roost-animations t) redrawn)
       (cl-letf (((symbol-function 'roost--redraw) (lambda () (setq redrawn t))))
         (with-temp-buffer
           (roost--status-light (roost--cache-task "dev" (roost-test--task nil "permission")) 'sidebar))
         (should (timerp roost--lights-timer))
         ;; Turned off, the lights go and the buffers that show are drawn again.
         (customize-set-variable 'roost-animations nil)
         (should-not roost-animations)
         (should redrawn)
         (should (zerop (hash-table-count roost--lights)))
         (should-not roost--lights-timer))))))

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
     (let ((working (append '((updatedAt . "2026-10-03T20:06:00+00:00")) (roost-test--task nil "running"))))
       (roost--mark-seen (roost--cache-task "dev" working))
       (should (equal (roost--attention-status (roost--cache-task "dev" working))
                      "running"))))))

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

(ert-deftest roost-a-view-that-fails-to-draw-stops-no-polls ()
  ;; Drawing a reply that failed, here in a broken search buffer, left the
  ;; host marked as refreshing, so it was never polled again, and called
  ;; the host offline with Roost's own error.
  (roost-test--isolated
   (let ((roost-hosts '("dev")) (attempts 0) (broken t))
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action _params success _failure)
                  (cl-incf attempts) (funcall success nil)))
               ((symbol-function 'roost--redraw)
                (lambda () (when broken (error "Broken view")))))
       (should-error (roost-refresh t))
       (should-not (gethash "dev" roost--refreshing))
       (setq broken nil)
       (roost-refresh t)
       (should (= attempts 2))))))

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

(ert-deftest roost-task-panel-shows-prompt-changes-and-details ()
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
                 ;; The menu has the actions.
                 (should-not (string-match-p "Merge and retire" text))
                 (should (string-match-p "^\\? opens the menu · g refreshes · q closes$" text))
                 (should (string-match-p "Branch       codex/roost/fix-auth-123456, from main, merges into main" text))
                 (should (string-match-p "Worktree     ~/work/fix auth" text))
                 ;; Line counts keep their colors inside the indented section.
                 (goto-char (point-min))
                 (search-forward "+2")
                 (should (memq 'roost-diff-added (ensure-list (get-text-property (1- (point)) 'face))))
                 (should (string-match-p "Conversation abc-123" text))
                 (should-not display-line-numbers))
             (kill-buffer))))))))

;; Global modes many configurations turn on.
(defvar global-display-line-numbers-mode)
(defvar global-visual-line-mode)

(ert-deftest roost-lists-keep-out-global-line-numbers-and-wrapping ()
  ;; Search results came later than the others, and showed line numbers
  ;; and wrapped every message, so TAB had nothing more to show.
  (let ((numbers (bound-and-true-p global-display-line-numbers-mode))
        (wrapping (bound-and-true-p global-visual-line-mode)))
    (unwind-protect
        (progn
          (global-display-line-numbers-mode 1)
          (global-visual-line-mode 1)
          (dolist (mode '(roost-dashboard-mode roost-search-mode roost-task-info-mode roost-doctor-mode))
            (with-temp-buffer
              (funcall mode)
              (should-not display-line-numbers)
              ;; Lists keep a line for each row.
              (when (memq mode '(roost-dashboard-mode roost-search-mode))
                (should-not visual-line-mode)
                (should truncate-lines)))))
      (global-display-line-numbers-mode (if numbers 1 -1))
      (global-visual-line-mode (if wrapping 1 -1)))))

(ert-deftest roost-merging-measures-the-other-tasks-again ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))) refreshes)
     (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
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
               ((symbol-function 'y-or-n-p) (lambda (_) t))
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
    (let ((task (roost--cache-task "dev" (roost-test--task))) sent buffer said)
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--refresh-host) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore)
                ((symbol-function 'message)
                 (lambda (format &rest args) (when format (setq said (apply #'format-message format args)))))
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
        ;; Said in a sentence, not as "Roost fix auth: send".
        (should (equal said "Sent to fix auth"))
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

(ert-deftest roost-a-reply-read-before-the-latest-event-keeps-it ()
  ;; A poll that took a while, read before the agent's turn ended, put the
  ;; task back to running after a newer reply had it ready.
  (roost-test--isolated
   (roost--cache-task "dev" (append '((updatedAt . "2026-10-13T10:31:36.627905+00:00") (lastEvent . "Stop")
                                      (agentSession . "after-clear"))
                                    (roost-test--task nil "ready")))
   (roost--cache-task "dev" (append '((updatedAt . "2026-10-13T10:31:36.510719+00:00") (lastEvent . "PostToolUse")
                                      (agentSession . "before-clear") (diff . "1 file changed")
                                      (pr (number . 9) (url . "https://github.com/o/r/pull/9")))
                                    (roost-test--task nil "running")))
   (let ((task (gethash '("dev" "0123456789abcdef") roost--tasks)))
     (should (equal (roost--field task 'status) "ready"))
     (should (equal (roost--field task 'lastEvent) "Stop"))
     (should (equal (roost--field task 'agentSession) "after-clear"))
     ;; What else it read is still news, such as a pull request it found on GitHub.
     (should (equal (roost--field task 'diff) "1 file changed"))
     (should (equal (alist-get 'number (roost--field task 'pr)) 9)))
   ;; Nor the pane of an agent stopped since.
   (roost--cache-task "dev" (append '((updatedAt . "2026-10-13T10:31:38+00:00") (paneId) (windowId) (live))
                                    (roost-test--task nil "stopped")))
   (roost--cache-task "dev" (append '((updatedAt . "2026-10-13T10:31:37+00:00") (live . t))
                                    (roost-test--task nil "ready")))
   (let ((task (gethash '("dev" "0123456789abcdef") roost--tasks)))
     (should (equal (roost--field task 'status) "stopped"))
     (should-not (roost--field task 'paneId))
     (should-not (roost--field task 'live)))
   ;; A newer one is taken whole.
   (roost--cache-task "dev" (append '((updatedAt . "2026-10-13T10:31:40+00:00") (lastEvent . "UserPromptSubmit"))
                                    (roost-test--task nil "running")))
   (should (equal (roost--field (gethash '("dev" "0123456789abcdef") roost--tasks) 'status) "running"))))

(ert-deftest roost-quiet-refresh-retains-pull-request-status ()
  (roost-test--isolated
   (roost--cache-task "dev" (roost-test--pr-task '(prStatus . ((state . "OPEN")))))
   (roost--apply-snapshot "dev" (list (roost-test--pr-task)))
   (should (alist-get 'prStatus (gethash '("dev" "0123456789abcdef") roost--tasks)))))

(ert-deftest roost-quiet-polls-ask-about-pull-requests-now-and-then ()
  ;; A merge on GitHub leaves no trace on the host for a poll to notice.
  (roost-test--isolated
   (let (asked)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host _action params _ok _fail) (push params asked))))
       (dolist (args '((t) (t) (nil ("0123456789abcdef")) (t)))
         (clrhash roost--refreshing)
         (apply #'roost--refresh-host "dev" args))
       (should (equal (nreverse asked) '(((full . :false) (pullRequests . t)) ((full . :false))
                                         ((full . ["0123456789abcdef"])) ((full . :false)))))
       ;; A full refresh asks GitHub, so the next quiet poll needn't.
       (puthash "dev" (- (float-time) roost--pull-request-interval 1) roost--pull-requests-asked)
       (setq asked nil)
       (dolist (quiet '(nil t))
         (clrhash roost--refreshing)
         (roost--refresh-host "dev" quiet))
       (should (equal (nreverse asked) '(((full . t)) ((full . :false)))))))))

(ert-deftest roost-a-merged-task-says-so-in-its-row ()
  (roost-test--isolated
   (let* ((seen '(seen . "2026-10-03T20:00:00+00:00"))
          (cache (lambda (id &rest fields)
                   (roost--cache-task "dev" (append fields `((repo . "/home/user/ledger") (live . t) (ahead . 2)
                                                             (dirty))
                                                    (roost-test--task id)))))
          (merged (funcall cache "1111111111111111" seen '(landed . t)
                           '(pr . ((number . 12) (url . "https://github.com/o/r/pull/12")))
                           '(prStatus . ((state . "MERGED")))))
          (unseen (funcall cache "2222222222222222" '(landed . t)))
          (dirty (funcall cache "3333333333333333" seen '(landed . t) '(dirty . t)))
          (later (funcall cache "4444444444444444" seen '(landed)
                          '(pr . ((number . 12) (url . "https://github.com/o/r/pull/12")))
                          '(prStatus . ((state . "MERGED"))))))
     (should (equal (roost--display-status merged) "merged"))
     (should (eq (roost--status-word-face (roost--attention-status merged)) 'roost-pr-merged))
     (should (equal (roost--next-step merged) "Its pull request is merged; x retires it"))
     ;; Anything that needs you comes first.
     (should (equal (roost--display-status unseen) "ready"))
     (should (equal (roost--display-status dirty) "ready"))
     ;; Commits since its pull request merged are not merged.
     (should (equal (roost--display-status later) "ready"))
     (should (equal (roost--next-step later) "Its pull request is merged, but not its commits since: m merges them"))
     (should (roost--action-applies-p later 'roost-merge-retire))
     (should-not (roost--action-applies-p merged 'roost-merge-retire))
     ;; Merged into its branch without GitHub, by an agent that has stopped:
     ;; once you have seen what it said last.
     (let ((stopped (funcall cache "5555555555555555" '(landed . t) '(status . "stopped") '(live))))
       (should (equal (roost--display-status stopped) "stopped"))
       (setq stopped (funcall cache "5555555555555555" seen '(landed . t) '(status . "stopped") '(live)))
       (should (equal (roost--display-status stopped) "merged"))
       (should (equal (roost--next-step stopped) "Its work is merged; x retires it")))
     (should (equal (roost--display-status (funcall cache "6666666666666666" '(landed . t) '(status . "running")))
                    "running"))
     ;; A failure shows, seen or not.
     (dolist (status '("failed" "crashed"))
       (should (equal (roost--display-status (funcall cache "7777777777777777" seen '(landed . t)
                                                      `(status . ,status) '(live)))
                      status)))
     (remhash '("dev" "7777777777777777") roost--tasks)
     ;; Known merged before its Git statistics are, as after a poll that only asked GitHub.
     (let ((unmeasured (roost--cache-task "dev" (append `(,seen (landed . t) (live . t) (ahead . 2))
                                                        (roost-test--task "8888888888888888")))))
       (should (equal (roost--display-status unmeasured) "ready"))
       (remhash '("dev" "8888888888888888") roost--tasks))
     (with-temp-buffer
       (roost-dashboard-mode)
       (roost--render-dashboard)
       (should (string-match-p "fix auth 111111 +merged +[0-9a-z]+ +#12 merged" (buffer-string)))
       (should (string-match-p "2 merged" (buffer-string))))
     (with-temp-buffer
       (roost-sidebar-list-mode)
       (roost--render-sidebar)
       (should (= (how-many "merged$" (point-min) (point-max)) 2)))
     ;; Retiring it asks only whether to.
     (let (asked)
       (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) nil)))
         (roost-retire (assq-delete-all 'prStatus (copy-tree merged))))
       (should (string-prefix-p "Retire fix auth" (car asked)))))))

(ert-deftest roost-a-pull-request-shows-its-recorded-state-before-github-answers ()
  (roost-test--isolated
   (should (eq (roost--pr-state (roost-test--task)) nil))
   (should (eq (roost--pr-state (roost-test--pr-task)) 'open))
   (let ((recorded (roost--cache-task "dev" (append '((pr . ((number . 12) (state . "MERGED")))
                                                      (seen . "2026-10-03T20:00:00+00:00") (live . t)
                                                      (ahead . 2) (landed . t))
                                                    (roost-test--task)))))
     (should (eq (roost--pr-state recorded) 'merged))
     ;; GitHub can't say now: the merge on record names it.
     (should (equal (roost--next-step recorded) "Its pull request is merged; x retires it")))
   ;; Nor for one open: P pushes to it, rather than opening another.
   (let ((open (roost--cache-task "dev" (append '((pr . ((number . 12) (state . "OPEN"))) (live . t) (ahead . 2))
                                                (roost-test--task "1111111111111111")))))
     (should (equal (roost--next-step open) "P pushes new commits to its pull request")))
   (should (eq (roost--pr-state (append '((prStatus . ((state . "OPEN"))) (pr . ((number . 12) (state . "MERGED"))))
                                        (roost-test--task)))
               'open))))

(ert-deftest roost-commits-since-a-merge-are-work-to-lose ()
  (roost-test--isolated
   (let ((later (roost--cache-task "dev" (append '((live . t) (ahead . 3) (landed) (dirty)
                                                   (pr . ((number . 12) (url . "https://github.com/o/r/pull/12")))
                                                   (prStatus . ((state . "MERGED"))))
                                                 (roost-test--task))))
         (unmeasured (roost-test--pr-task '(live . t) '(ahead . 3) '(prStatus . ((state . "MERGED"))))))
     (should (roost--unmerged-work-p later))
     ;; Before Git is measured, the merge on GitHub is all there is to go on.
     (should-not (roost--unmerged-work-p unmeasured))
     ;; Unless its host has said its commits aren't all merged.
     (let ((said (roost-test--pr-task '(live . t) '(ahead . 3) '(landed) '(prStatus . ((state . "MERGED"))))))
       (should (roost--unmerged-work-p said))
       (should (roost--action-applies-p said 'roost-merge-retire)))
     (let (asked)
       (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) nil)))
         (roost-retire later))
       (should (string-match-p "has work not merged" (car asked)))))))

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

(ert-deftest roost-a-task-keeps-its-tab-when-another-of-its-name-comes-and-goes ()
  (roost-test--isolated
   (let* ((roost-workspace 'tab-bar)
          (first (roost--cache-task "dev" (cons '(startedAt . "2026-10-03T20:00:00Z") (roost-test--task))))
          (second (cons '(startedAt . "2026-10-03T21:00:00Z") (roost-test--task "fedcba9876543210")))
          (tabs (length (roost--tabs)))
          (original-tab-bar-mode tab-bar-mode))
     (unwind-protect
         (progn
           (roost--activate-workspace first)
           (setq second (roost--cache-task "dev" second))
           ;; The first keeps its name; the second's tab has its ID.
           (should (equal (roost--key (roost--frame-task)) (roost--key first)))
           (roost--activate-workspace second)
           (should (equal (roost--current-workspace) "dev/fix auth:fedcba"))
           (roost--activate-workspace first)
           (should (equal (roost--current-workspace) "dev/fix auth"))
           (should (= (length (roost--tabs)) (+ tabs 2)))
           ;; Once the first is gone, the second keeps the tab it has.
           (roost--retired-workspace first)
           (roost--apply-snapshot "dev" (list second))
           (should-not (member "dev/fix auth" (roost--tabs)))
           (roost--activate-workspace second)
           (should (equal (roost--current-workspace) "dev/fix auth:fedcba"))
           (should (= (length (roost--tabs)) (+ tabs 1)))
           (should (equal (roost--key (roost--frame-task)) (roost--key second))))
       (while (cdr (roost--tabs)) (tab-bar-close-tab))
       ;; A second tab shows the tab bar.
       (unless original-tab-bar-mode (tab-bar-mode -1))))))

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
                                          (hint . "Fix it"))
                                         ((name . "Push · qa-project") (ok) (optional . t)
                                          (detail . "no origin remote"))))
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
                 ;; A name longer than the column keeps a space before its detail.
                 (should (string-match-p "– Push · qa-project no origin remote" text))
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
  ;; It has no mode line, so nothing said you were in it, or which task
  ;; `s' would resume.
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
             (should (= (overlay-start roost--selection) (funcall row "beta")))
             (should (eq (overlay-get roost--selection 'window) (selected-window)))
             ;; It follows point, and outlasts a redraw.
             (goto-char (funcall row "alpha"))
             (roost--sidebar-mark-selection)
             (roost--render-sidebar)
             (should (= (overlay-start roost--selection) (funcall row "alpha")))
             ;; Once in, point can rest on a project's heading, for `c',
             ;; and stays there through a redraw.
             (goto-char (funcall row "dev · p"))
             (roost--sidebar-mark-selection)
             (roost--render-sidebar)
             (should (= (point) (funcall row "dev · p")))
             (should (= (overlay-start roost--selection) (funcall row "dev · p"))))
           ;; So may a click that enters the sidebar there.
           (set-window-point (selected-window) (funcall row "dev · p"))
           (let ((last-input-event `(mouse-1 (,(selected-window) ,(funcall row "dev · p") (0 . 0) 0))))
             (roost--sidebar-entered))
           (should (= (window-point) (funcall row "dev · p")))
           ;; Elsewhere, the sidebar shows no selection, and no cursor.
           (set-window-buffer (selected-window) (get-buffer-create " *elsewhere*"))
           (roost--sidebar-mark-selection)
           (with-current-buffer sidebar
             (should-not (overlay-buffer roost--selection))
             (should-not cursor-in-non-selected-windows)
             ;; In it, the cursor is the frame's: modal editing shows its state with it.
             (should-not (local-variable-p 'cursor-type))))
       (kill-buffer sidebar)
       (when (get-buffer " *elsewhere*") (kill-buffer " *elsewhere*"))))))

(ert-deftest roost-a-task-panel-highlights-the-line-you-are-on-while-you-are-in-it ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task)))
         (panel (get-buffer-create " *roost-test-panel*")))
     (unwind-protect
         (save-window-excursion
           (with-current-buffer panel
             (roost-task-info-mode)
             (setq roost--buffer-task-key (roost--key task))
             (roost--render-task-info))
           ;; Not in it: no highlight.
           (with-current-buffer panel
             (should-not (and roost--selection (overlay-buffer roost--selection))))
           (set-window-buffer (selected-window) panel)
           (roost--selection-changed (selected-window))
           (with-current-buffer panel
             (should (eq (overlay-get roost--selection 'window) (selected-window)))
             (should (= (overlay-start roost--selection) (line-beginning-position)))
             ;; It follows point, and outlasts a redraw.
             (forward-line 1)
             (set-window-point (selected-window) (point))
             (roost--mark-selection)
             (roost--render-task-info)
             (should (= (overlay-start roost--selection)
                        (save-excursion (goto-char (point-min)) (line-beginning-position 2)))))
           ;; Leaving it removes the highlight.
           (set-window-buffer (selected-window) (get-buffer-create " *elsewhere*"))
           (with-current-buffer panel
             (roost--mark-selection)
             (should-not (overlay-buffer roost--selection))))
       (kill-buffer panel)
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
       (should (equal (car messages) "Roost dev: ssh: connect to host dev port 22: Operation timed out"))
       ;; Asked once a question you are answering is done.
       (setq reply "The agent's tmux window is gone; resume the task")
       (let ((minibuffer t))
         (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () minibuffer)))
           (roost-open-task task)
           (should-not asked)
           (setq minibuffer nil)
           (run-hooks 'minibuffer-exit-hook)
           (accept-process-output nil 0.05)
           (should asked)))))))

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

;;;; From a hands-on design review

(ert-deftest roost-a-new-task-starts-in-the-project-you-are-in ()
  (roost-test--isolated
   (let* ((repo (file-name-as-directory (file-truename (make-temp-file "roost-here" t))))
          (sub (expand-file-name "src/" repo)))
     (unwind-protect
         (progn
           (let ((default-directory repo)) (call-process "git" nil nil nil "init" "-q"))
           (make-directory sub)
           ;; A project Roost knows of, on another host, must not stand in.
           (roost--cache-task "dev" (append '((repo . "/home/user/repo")) (roost-test--task)))
           (save-window-excursion
             (with-temp-buffer
               (setq default-directory sub)
               (roost--compose)
               (with-current-buffer roost--compose-buffer
                 (should (equal (plist-get roost--compose-fields :directory) repo))))))
       (when (get-buffer roost--compose-buffer) (kill-buffer roost--compose-buffer))
       (delete-directory repo t)))))

(ert-deftest roost-the-project-picker-offers-project-el-checkouts ()
  (roost-test--isolated
   (let ((repo (file-name-as-directory (file-truename (make-temp-file "roost-known" t))))
         (plain (file-name-as-directory (file-truename (make-temp-file "roost-plain" t)))))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".git" repo))
           (roost--cache-task "dev" (append '((repo . "/home/user/repo")) (roost-test--task)))
           ;; Loaded first, so that it does not replace the stand-in.
           (require 'project)
           (cl-letf (((symbol-function 'project-known-project-roots)
                      (lambda () (list repo plain "/ssh:other:/srv/app/"))))
             (let ((choices (roost--project-choices)))
               (should (string-suffix-p ":/home/user/repo/" (car choices)))
               (should (member repo choices))
               (should (member "/ssh:other:/srv/app/" choices))
               (should-not (member plain choices)))))
       (delete-directory repo t)
       (delete-directory plain t)))))

(ert-deftest roost-pickers-keep-their-order ()
  ;; Vertico sorts candidates by length unless told not to, which put
  ;; "Other directory…" above the projects you used last.
  (let (shown sort)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (setq shown (funcall table "" nil t)
                       sort (alist-get 'display-sort-function (cdr (funcall table "" nil 'metadata))))
                 (car shown))))
      (should (equal (roost--choose-from "Project: " '(("dev · ~/work/ledger" . "/ssh:dev:/work/ledger/")
                                                       ("Other directory…" . other)))
                     "/ssh:dev:/work/ledger/"))
      (should (equal shown '("dev · ~/work/ledger" "Other directory…")))
      (should (eq sort 'identity)))))

(ert-deftest roost-an-interrupted-turn-says-so ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((lastEvent . "Interrupt") (live . t)) (roost-test--task)))))
     (should (equal (roost--display-status task) "interrupted"))
     (should (roost--waiting-p task))
     (should (equal (roost--status-face "interrupted") 'roost-status-ready))
     (should (equal (substring-no-properties (roost--next-step task))
                    "You stopped its last turn; tell it what to do instead: e"))
     (should (equal (substring-no-properties (roost--summary (list task))) "1 interrupted"))
     ;; Once seen it waits no longer, as a finished turn would.
     (puthash (roost--key task) (roost--field task 'updatedAt) roost--seen)
     (should (equal (roost--attention-status task) "idle"))
     (should-not (roost--waiting-p task))
     ;; A turn that finishes is ready again.
     (setq task (roost--cache-task "dev" (append '((lastEvent . "Stop") (live . t)
                                                   (updatedAt . "2026-10-03T21:00:00+00:00"))
                                                 (roost-test--task))))
     (should (equal (roost--display-status task) "ready")))))

(ert-deftest roost-update-offers-the-agent-uncommitted-changes ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (append '((integrationBranch . "main")) (roost-test--task))))
         sent answer shown)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host action params _success failure)
                  (if (equal action "update")
                      (funcall failure "Commit the task's changes before updating it from main")
                    (setq sent (alist-get 'text params)))))
               ((symbol-function 'y-or-n-p) (lambda (_) answer))
               ((symbol-function 'message)
                (lambda (format &rest args) (setq shown (apply #'format-message format args)))))
       (roost-update task)
       (should-not sent)
       (should (string-match-p "\\`Commit fix auth.s changes in Magit (r), then update it again" shown))
       (setq answer t)
       (roost-update task)
       (should (string-prefix-p "Commit your changes, then merge main into this branch." sent))))))

(ert-deftest roost-merge-style-squashes-unless-asked-to-merge ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task))) params question)
     (cl-letf (((symbol-function 'roost--request)
                (lambda (_host action request &rest _)
                  (when (equal action "merge") (setq params request))))
               ((symbol-function 'y-or-n-p) (lambda (prompt) (setq question prompt) t))
               ((symbol-function 'roost--release-terminal) #'ignore))
       (roost-merge-retire task)
       (should (equal (alist-get 'style params) "squash"))
       (should (string-prefix-p "Squash committed work from fix auth into one commit" question))
       (let ((roost-merge-style 'merge))
         (roost-merge-retire task))
       (should (assq 'id params))
       (should-not (assq 'style params))
       (should (string-prefix-p "Merge committed work from fix auth" question))))))

(ert-deftest roost-task-commands-are-greyed-out-with-no-tasks ()
  (roost-test--isolated
   (with-temp-buffer
     (should (roost--dispatch-inapt-p 'roost-shell))
     (should-not (roost--menu-applies-p 'roost-shell))
     (roost--cache-task "dev" (roost-test--task))
     ;; With tasks but none at point, the command asks which.
     (should-not (roost--dispatch-inapt-p 'roost-shell))
     (should (roost--menu-applies-p 'roost-shell)))))

(ert-deftest roost-doctor-says-how-magit-reaches-a-host ()
  (roost-test--isolated
   (let ((tramp-default-method "scp"))
     (pcase-let ((`(,name ,ok ,detail ,hint) (roost--doctor-review-check "dev")))
       (should (equal name "Magit"))
       (should (eq ok 'optional))
       (should (equal detail "over TRAMP's scp method"))
       (should (string-match-p "tramp-rpc" hint))
       (should (string-match-p "Remote review" hint))))))

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

(ert-deftest roost-drafts-follow-notes-edited-or-removed-after-them ()
  (roost-test--isolated
   (roost-test--with-send-buffers
    (let* ((task (roost--cache-task "dev" (roost-test--task)))
           (id (roost--field task 'id))
           sent)
      (setq roost--notes (list (roost-test--note "1" id '(file . "a.py") '(text . "One"))
                               (roost-test--note "2" id '(file . "b.py") '(text . "Two"))
                               (roost-test--note "3" id '(file . "c.py") '(text . "Three"))))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer)
                ((symbol-function 'roost--refresh-host) #'ignore)
                ((symbol-function 'roost--redraw) #'ignore)
                ((symbol-function 'roost--request)
                 (lambda (_host _action params success &rest _)
                   (setq sent params)
                   (funcall success (roost-test--task)))))
        (roost--send-draft task)
        (let ((draft (current-buffer)))
          ;; Edited, a note changes in the draft too.
          (roost--edit-note (nth 0 roost--notes) "One, edited")
          (should (equal (buffer-string) "\n\na.py\nOne, edited\n\nb.py\nTwo\n\nc.py\nThree"))
          ;; Removed, it leaves the draft, and its neighbours one blank line apart.
          (roost--remove-notes (lambda (note) (equal (alist-get 'id note) "2")))
          (should (equal (buffer-string) "\n\na.py\nOne, edited\n\nc.py\nThree"))
          ;; A note you changed in the draft stays as you wrote it there, and
          ;; once sent the note itself is kept, edited.
          (goto-char (point-max))
          (insert " for sure")
          (roost--edit-note (nth 1 roost--notes) "Three, edited")
          (should (string-suffix-p "c.py\nThree for sure" (buffer-string)))
          (with-current-buffer draft (roost-send-submit))
          (should (equal (alist-get 'text sent) "a.py\nOne, edited\n\nc.py\nThree for sure"))
          (should (equal (mapcar (lambda (note) (alist-get 'text note)) roost--notes)
                         '("Three, edited")))))))))

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

(defun roost-test--write-note (text &optional initial)
  "Write TEXT in the note box `roost-note' opens here, and save it.
With INITIAL, the box must start out holding it."
  (save-current-buffer
    (roost-note)
    (with-current-buffer (plist-get roost--note-box :buffer)
      (should (derived-mode-p 'roost-note-box-mode))
      (when initial (should (equal (buffer-string) initial)))
      (erase-buffer)
      (insert text)
      (roost-note-box-save)))
  (should-not roost--note-box))

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
      ;; An added line.
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "Name it")
      ;; A context line and the added one, as a region.
      (roost-test--goto-line-text "line 4")
      (set-mark (point))
      (forward-line 2)
      (activate-mark)
      (roost-test--write-note "These two")
      (should-not (use-region-p))
      ;; The whole file, from its name.
      (goto-char (point-min))
      (re-search-forward "^modified +a.txt")
      (roost-test--write-note "Whole file")
      (should (equal (mapcar (lambda (note) (roost--format-note note)) roost--notes)
                     '("a.txt:5\n> +new line\nName it"
                       "a.txt:4-5\n>  line 4\n> +new line\nThese two"
                       "a.txt\nWhole file")))
      (should (equal (roost-test--shown-notes)
                     '(("modified   a.txt" . "Whole file")
                       ("+new line" . "Name it")
                       ("+new line" . "These two"))))
      ;; On a noted line, the note is edited; saved empty, removed.
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "" "Name it")
      (should (equal (mapcar (lambda (note) (alist-get 'text note)) roost--notes)
                     '("These two" "Whole file"))))))

(ert-deftest roost-a-note-on-a-region-stays-within-one-hunk ()
  (roost-test--with-magit-task
    ;; Changes at the first and last lines make two hunks.
    (roost-test--write-lines "a.txt" (append '(0) (number-sequence 2 9) '(11)))
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (dolist (forward '(t nil))
        (roost-test--goto-line-text (if forward "line 0" "line 11"))
        (set-mark (point))
        (roost-test--goto-line-text (if forward "line 11" "line 0"))
        (activate-mark)
        (should-error (roost-note) :type 'user-error)
        (should-not roost--note-box)
        (deactivate-mark))
      (should-not roost--notes)
      ;; Within one hunk, a region is fine.
      (roost-test--goto-line-text "line 1")
      (set-mark (point))
      (forward-line 2)
      (activate-mark)
      (roost-test--write-note "Why?")
      (should (equal (roost--format-note (car roost--notes))
                     "a.txt:1\n> -line 1\n> +line 0\nWhy?")))))

(ert-deftest roost-a-note-shows-under-the-last-line-chosen ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (append (number-sequence 1 4) (number-sequence 6 10)))
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      ;; An unchanged line, then the removed one after it.
      (roost-test--goto-line-text "line 4")
      (set-mark (point))
      (forward-line 2)
      (activate-mark)
      (roost-test--write-note "Keep this")
      (should (equal (roost--format-note (car roost--notes))
                     "a.txt:4\n>  line 4\n> -line 5\nKeep this"))
      (should (equal (roost-test--shown-notes) '(("-line 5" . "Keep this")))))))

(ert-deftest roost-notes-follow-their-line-when-the-agent-edits-above-it ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      ;; A removed line keeps the old version's numbers.
      (roost-test--write-lines "a.txt" (append '(1 2 3 4) (number-sequence 6 10)) "new line\n")
      (magit-refresh)
      (roost-test--goto-line-text "line 5")
      (roost-test--write-note "Removed?")
      (should (equal (roost--format-note (car roost--notes))
                     "a.txt:5 (a removed line)\n> -line 5\nRemoved?"))
      ;; The agent adds two lines at the top: the note moves with its line.
      (roost-test--write-lines "a.txt" (append '(0 0 1 2 3 4) (number-sequence 6 10)) "new line\n")
      (magit-refresh)
      (should (equal (roost-test--shown-notes) '(("-line 5" . "Removed?")))))))

(ert-deftest roost-the-note-box-cancels-and-keeps-what-you-wrote ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      ;; Cancelled, the box leaves no note.
      (roost-test--goto-line-text "new line")
      (save-current-buffer
        (roost-note)
        (with-current-buffer (plist-get roost--note-box :buffer)
          (insert "Never mind")
          (roost-note-box-cancel)))
      (should-not roost--note-box)
      (should-not roost--notes)
      ;; A note being written is saved when another box opens.
      (save-current-buffer
        (roost-note)
        (with-current-buffer (plist-get roost--note-box :buffer) (insert "Keep me")))
      (roost-test--goto-line-text "line 4")
      (save-current-buffer (roost-note))
      (should (equal (mapcar (lambda (note) (alist-get 'text note)) roost--notes) '("Keep me")))
      (should (equal (alist-get 'line (plist-get roost--note-box :place)) 4))
      (roost-note-box-cancel)
      (should (equal (roost-test--shown-notes) '(("+new line" . "Keep me")))))))

(defun roost-test--margin-event (kind from &optional to)
  "A mouse event of KIND in the left margin, from position FROM to TO."
  (let ((posn (lambda (position)
                (list (selected-window) 'left-margin '(1 . 1) 0 nil position '(0 . 0) nil '(1 . 1) '(10 . 10)))))
    (if to
        (list kind (funcall posn from) (funcall posn to))
      (list kind (funcall posn from)))))

(ert-deftest roost-notes-are-written-with-the-mouse ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (let ((buffer (magit-get-mode-buffer 'magit-diff-mode)))
      (set-window-buffer (selected-window) buffer)
      (with-current-buffer buffer
        ;; A click beside a line.
        (roost-test--goto-line-text "new line")
        (let ((line (point)))
          (goto-char (point-min))
          (save-current-buffer (roost-note-mouse (roost-test--margin-event 'mouse-1 (+ line 3)))))
        (should (equal (alist-get 'line (plist-get roost--note-box :place)) 5))
        (roost-note-box-cancel)
        ;; A drag up along lines.
        (let ((from (progn (roost-test--goto-line-text "new line") (point)))
              (to (progn (roost-test--goto-line-text "line 3") (point))))
          (save-current-buffer (roost-note-mouse (roost-test--margin-event 'drag-mouse-1 from to))))
        (should (equal (roost--note-location (plist-get roost--note-box :place)) "a.txt:3-5"))
        (roost-note-box-cancel)
        ;; Beside a heading, a click only moves point.
        (save-current-buffer (roost-note-mouse (roost-test--margin-event 'mouse-1 (point-min))))
        (should-not roost--note-box)
        (should (= (point) (point-min)))))))

(ert-deftest roost-the-note-button-follows-the-mouse-over-diff-lines ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    ;; As in a graphic frame, but with the button as text.
    (cl-letf (((symbol-function 'display-graphic-p) #'always)
              ((symbol-function 'display-images-p) #'ignore))
      (magit-diff-unstaged)
      (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
        (unwind-protect
            (progn
              (should (= left-margin-width 2))
              (should (overlayp roost--note-hover))
              ;; Windows that show the buffer later are set up then.
              (should (memq #'roost--note-margins-shown window-buffer-change-functions))
              (roost-test--goto-line-text "new line")
              (let ((line (point)))
                (roost--note-hover-echo (selected-window) roost--note-hover (+ line 2))
                (should (eq (overlay-buffer roost--note-button) (current-buffer)))
                (should (= (overlay-start roost--note-button) line))
                (should (string-prefix-p "mouse-1" (get-text-property 0 'help-echo (overlay-get roost--note-button 'before-string)))))
              ;; Over a heading, it goes.
              (roost--note-hover-echo (selected-window) roost--note-hover (point-min))
              (should-not (overlay-buffer roost--note-button))
              ;; Without Roost, so does the margin.
              (roost-magit-mode -1)
              (should (= left-margin-width 0))
              (should-not roost--note-hover)
              (should-not (memq #'roost--note-margins-shown window-buffer-change-functions))
              ;; A wider margin of the buffer's own stays, and comes back.
              (setq left-margin-width 3)
              (roost-magit-mode 1)
              (should (= left-margin-width 3))
              (should (overlayp roost--note-hover))
              (roost-magit-mode -1)
              (should (= left-margin-width 3)))
          (when (timerp roost--note-mouse-timer)
            (cancel-timer roost--note-mouse-timer)
            (setq roost--note-mouse-timer nil)))))))

(ert-deftest roost-goes-to-a-note-chosen-in-the-minibuffer ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "Name it\nwith care")
      (roost-test--goto-line-text "line 2")
      (roost-test--write-note "Fine")
      (goto-char (point-min))
      (let (choices)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _)
                     (setq choices (all-completions "" table))
                     (car choices))))
          (save-current-buffer (roost-goto-note task)))
        (should (equal choices '("1. a.txt:5  Name it" "2. a.txt:2  Fine")))
        (should (equal (buffer-substring-no-properties (point) (line-end-position)) "+new line"))))))

(ert-deftest roost-a-note-clicked-is-edited-sent-or-discarded ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (set-window-buffer (selected-window) (current-buffer))
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "Name it")
      (roost-test--goto-line-text "line 2")
      (roost-test--write-note "Fine")
      (let* (choice sent
             (click (lambda (text)
                      (let* ((overlay (seq-find (lambda (overlay)
                                                  (equal (alist-get 'text (car (overlay-get overlay 'roost-notes)))
                                                         text))
                                                roost--note-overlays))
                             (string (overlay-get overlay 'after-string)))
                        (save-current-buffer
                          (roost-note-mouse-menu
                           (list 'mouse-1 (list (selected-window) (overlay-end overlay) '(1 . 1) 0
                                                (cons string 5) (overlay-end overlay)))))))))
        (cl-letf (((symbol-function 'x-popup-menu) (lambda (&rest _) choice))
                  ((symbol-function 'roost--send-text)
                   (lambda (_task text callback &rest _) (setq sent text) (funcall callback task))))
          (setq choice 'edit)
          (funcall click "Name it")
          (should (equal (roost--note-box-text) "Name it"))
          (roost-note-box-cancel)
          (setq choice 'send)
          (funcall click "Name it")
          (should (equal sent "a.txt:5\n> +new line\nName it"))
          (setq choice 'discard)
          (funcall click "Fine")
          (should-not roost--notes))))))

(ert-deftest roost-a-note-edited-while-it-is-sent-stays ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task "a"))) done)
     (setq roost--notes (list (roost-test--note "1" "a" '(file . "x") '(text . "Old"))))
     (cl-letf (((symbol-function 'roost--send-text)
                (lambda (_task _text callback &rest _) (setq done callback)))
               ((symbol-function 'roost--redraw) #'ignore))
       (roost-note-send (car roost--notes))
       (roost--edit-note (car roost--notes) "New")
       (funcall done task)
       (should (equal (mapcar (lambda (note) (alist-get 'text note)) roost--notes) '("New")))
       ;; Unchanged, a note sent is cleared.
       (roost-note-send (car roost--notes))
       (funcall done task)
       (should-not roost--notes)))))

(ert-deftest roost-a-note-box-set-aside-saves-as-save-would ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "Name it")
      ;; Emptied, then left for another line: the note goes.
      (save-current-buffer
        (roost-note)
        (with-current-buffer (plist-get roost--note-box :buffer) (erase-buffer)))
      (roost-test--goto-line-text "line 4")
      (save-current-buffer (roost-note))
      (should-not roost--notes)
      ;; A new note left empty is no note.
      (roost-test--goto-line-text "line 2")
      (save-current-buffer (roost-note))
      (should-not roost--notes)
      (roost-note-box-cancel))))

(ert-deftest roost-a-note-edited-after-it-has-gone-is-written-anew ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "Name it")
      (save-current-buffer
        (roost-note)
        (with-current-buffer (plist-get roost--note-box :buffer)
          (erase-buffer)
          (insert "Rename it")
          ;; Sent meanwhile, from another window.
          (roost--remove-notes #'always)
          (roost-note-box-save)))
      (should (equal (mapcar (lambda (note) (roost--format-note note)) roost--notes)
                     '("a.txt:5\n> +new line\nRename it")))
      (should (= (length (seq-filter (lambda (field) (eq (car-safe field) 'id)) (car roost--notes)))
                 1)))))

(ert-deftest roost-the-room-for-a-note-box-is-in-its-window-only ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "Name it")
      (unwind-protect
          (progn
            ;; As a box in a child frame would be, for another note here.
            (setq roost--note-box (list :source (current-buffer) :frame 'shown :room 40
                                        :window (selected-window)
                                        :place (roost--magit-note-place)))
            (roost--show-notes-here task)
            (let ((room (seq-find (lambda (overlay) (overlay-get overlay 'roost-note-box))
                                  roost--note-overlays))
                  (notes (seq-find (lambda (overlay) (overlay-get overlay 'roost-notes))
                                   roost--note-overlays)))
              (should (eq (overlay-get room 'window) (selected-window)))
              ;; After the line's notes.
              (should (= (overlay-start room) (overlay-end notes)))
              (should-not (string-match-p "\n.*\n" (overlay-get notes 'after-string)))))
        (setq roost--note-box nil)))))

(ert-deftest roost-the-note-button-slows-down-while-the-mouse-rests ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (cl-letf (((symbol-function 'display-graphic-p) #'always)
              ((symbol-function 'display-images-p) #'ignore))
      (magit-diff-unstaged)
      (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
        (set-window-buffer (selected-window) (current-buffer))
        (roost-test--goto-line-text "new line")
        (let* ((line (point))
               (window (selected-window))
               (mouse (cons (selected-frame) (cons 10 10)))
               (state (list nil 0))
               (interval roost--note-mouse-interval)
               (follow (lambda ()
                         (roost--note-follow-mouse state interval)
                         (when (timerp roost--note-mouse-timer)
                           (setq interval (timer--repeat-delay roost--note-mouse-timer))))))
          (unwind-protect
              (cl-letf (((symbol-function 'mouse-pixel-position) (lambda () mouse))
                        ((symbol-function 'window-at-x-y) (lambda (&rest _) (and (cadr mouse) window)))
                        ((symbol-function 'posn-at-x-y)
                         (lambda (&rest _) (list window line '(10 . 10) 0 nil line))))
                (roost--note-hover-echo window roost--note-hover line)
                ;; Only in the window under the mouse.
                (should (eq (overlay-get roost--note-button 'window) window))
                (dotimes (_ 10) (funcall follow))
                (should (= interval 1))
                (should (overlay-buffer roost--note-button))
                ;; Moving, it looks faster again; leaving, the button goes.
                (setq mouse (cons (selected-frame) (cons 12 10)))
                (funcall follow)
                (should (= interval roost--note-mouse-interval))
                (setq mouse (cons (selected-frame) (cons nil nil)))
                (funcall follow)
                (should-not (overlay-buffer roost--note-button))
                (should-not roost--note-mouse-timer))
            (when (timerp roost--note-mouse-timer)
              (cancel-timer roost--note-mouse-timer)
              (setq roost--note-mouse-timer nil))))))))

(ert-deftest roost-unloading-stops-following-the-mouse ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (cl-letf (((symbol-function 'display-graphic-p) #'always)
              ((symbol-function 'display-images-p) #'ignore))
      (magit-diff-unstaged)
      (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
        (roost-test--goto-line-text "new line")
        (unwind-protect
            (progn
              (roost--note-hover-echo (selected-window) roost--note-hover (point))
              (should (timerp roost--note-mouse-timer))
              (roost--magit-teardown)
              (should-not roost--note-mouse-timer)
              (should-not (overlay-buffer roost--note-button)))
          (when (timerp roost--note-mouse-timer)
            (cancel-timer roost--note-mouse-timer)
            (setq roost--note-mouse-timer nil)))))))

(ert-deftest roost-a-note-box-keeps-nothing-for-a-task-gone-meanwhile ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (roost-test--goto-line-text "new line")
      (let ((gone (lambda () (remhash (roost--key task) roost--tasks))))
        ;; Saved, it is refused, with the box still open.
        (save-current-buffer
          (roost-note)
          (with-current-buffer (plist-get roost--note-box :buffer) (insert "Too late")))
        (funcall gone)
        (should-error (roost-note-box-save) :type 'user-error)
        (should roost--note-box)
        ;; Set aside, it is dropped.
        (roost--note-box-close t)
        (should-not roost--note-box)
        (should-not roost--notes)))))

(ert-deftest roost-a-note-box-killed-closes-once ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (roost-test--goto-line-text "new line")
      (save-current-buffer (roost-note))
      (let ((buffer (plist-get roost--note-box :buffer))
            (kills 0))
        (cl-letf* ((kill (symbol-function 'kill-buffer))
                   ((symbol-function 'kill-buffer)
                    (lambda (&optional b) (cl-incf kills) (funcall kill b))))
          (kill-buffer buffer))
        (should (= kills 1))
        (should-not (buffer-live-p buffer))
        (should-not roost--note-box)))))

(ert-deftest roost-a-note-box-closes-with-its-frame ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (roost-test--goto-line-text "new line")
      (save-current-buffer
        (roost-note)
        (with-current-buffer (plist-get roost--note-box :buffer) (insert "Keep me")))
      ;; As if the box were a child frame of this one, deleted with C-x 5 0:
      ;; the hook runs while the frame is still there.
      (let ((buffer (plist-get roost--note-box :buffer)))
        (setq roost--note-box (plist-put roost--note-box :frame (selected-frame)))
        (add-hook 'delete-frame-functions #'roost--note-box-frame-deleted)
        (roost--note-box-frame-deleted (selected-frame))
        (should (frame-live-p (selected-frame)))
        (should-not roost--note-box)
        (should-not (buffer-live-p buffer))
        (should-not (memq #'roost--note-box-frame-deleted delete-frame-functions))
        (should (equal (mapcar (lambda (note) (alist-get 'text note)) roost--notes) '("Keep me")))))))

(ert-deftest roost-a-note-is-acted-on-from-the-keyboard ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (with-current-buffer (magit-get-mode-buffer 'magit-diff-mode)
      (should (eq (key-binding (kbd "C-c ;")) #'roost-note-actions))
      (roost-test--goto-line-text "new line")
      (roost-test--write-note "Name it")
      ;; A second note under the same line, on it and the one before.
      (roost-test--goto-line-text "line 4")
      (set-mark (point))
      (forward-line 2)
      (activate-mark)
      (roost-test--write-note "These two")
      (roost-test--goto-line-text "new line")
      (let ((choices (list 'edit)))
        (cl-letf (((symbol-function 'x-popup-menu)
                   (lambda (_where menu)
                     ;; First which note, then what to do with it.
                     (if (equal (car menu) "Review notes")
                         (cdr (assoc "These two" (cdr (cadr menu))))
                       (pop choices)))))
          (save-current-buffer (roost-note-actions))))
      (should (equal (roost--note-box-text) "These two"))
      (roost-note-box-cancel)
      (roost-test--goto-line-text "line 2")
      (should-error (roost-note-actions) :type 'user-error))))

(ert-deftest roost-a-note-is-sent-once-at-a-time ()
  (roost-test--isolated
   (let ((task (roost--cache-task "dev" (roost-test--task "a"))) callbacks)
     (setq roost--notes (list (roost-test--note "1" "a" '(file . "x") '(text . "Once"))))
     (cl-letf (((symbol-function 'roost--send-text)
                (lambda (_task _text done failed) (push (cons done failed) callbacks)))
               ((symbol-function 'roost--redraw) #'ignore))
       (roost-note-send (car roost--notes))
       (should-error (roost-note-send (car roost--notes)) :type 'user-error)
       (should (= (length callbacks) 1))
       ;; Failed, it can be sent again; sent, it is cleared.
       (funcall (cdr (pop callbacks)) "no host")
       (roost-note-send (car roost--notes))
       (funcall (car (pop callbacks)) task)
       (should-not roost--notes)
       (should-not roost--notes-sending)))))

(ert-deftest roost-goes-to-a-note-on-committed-work-or-a-folded-hunk ()
  (roost-test--with-magit-task
    (let ((base (string-trim (shell-command-to-string "git rev-parse HEAD"))))
      (setq task (roost--cache-task nil (append `((baseCommit . ,base)) task)))
      ;; Committed on the task's branch, the line is no longer in Magit's
      ;; status.
      (call-process "git" nil nil nil "checkout" "-qb" "roost/a-line")
      (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
      (call-process "git" nil nil nil "commit" "-qam" "Add a line")
      (setq roost--notes (list `((id . "1") (host) (task . ,(roost--field task 'id))
                                 (file . "a.txt") (line . 5) (end . 5) (anchorLine . 5)
                                 (quote "+new line") (text . "Name it"))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _) (car (all-completions "" table))))
                ((symbol-function 'roost--activate-workspace) #'ignore))
        (save-current-buffer
          (roost-goto-note task)
          (should (derived-mode-p 'magit-diff-mode))
          (should (equal (buffer-substring-no-properties (point) (line-end-position)) "+new line"))
          ;; Folded, the hunk opens again.
          (goto-char (point-min))
          (re-search-forward "^@@")
          (magit-section-hide (magit-current-section))
          (goto-char (point-min)))
        (save-current-buffer
          (roost-goto-note task)
          (should (equal (buffer-substring-no-properties (point) (line-end-position)) "+new line"))
          (should-not (invisible-p (point))))
        ;; A line gone from the task's changes is said to be.
        (setq roost--notes (list `((id . "2") (host) (task . ,(roost--field task 'id))
                                   (file . "b.txt") (line . 1) (end . 1)
                                   (quote "+gone") (text . "Where?"))))
        (should-error (save-current-buffer (roost-goto-note task)) :type 'user-error)))))

(ert-deftest roost-a-whole-file-note-shown-twice-is-edited-where-clicked ()
  (roost-test--with-magit-task
    ;; Staged, and changed again since: the file is under both headings.
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (call-process "git" nil nil nil "add" "a.txt")
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "newer line\n")
    (magit-status-setup-buffer dir)
    (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
      (set-window-buffer (selected-window) (current-buffer))
      (goto-char (point-min))
      (re-search-forward "^modified +a.txt")
      (roost-test--write-note "Whole file")
      (let* ((copies (sort (seq-filter (lambda (overlay) (overlay-get overlay 'roost-notes))
                                       roost--note-overlays)
                           (lambda (a b) (< (overlay-start a) (overlay-start b)))))
             (last (car (last copies))))
        (should (= (length copies) 2))
        (cl-letf (((symbol-function 'x-popup-menu) (lambda (&rest _) 'edit)))
          (save-current-buffer
            (roost-note-mouse-menu
             (list 'mouse-1 (list (selected-window) (overlay-end last) '(1 . 1) 0
                                  (cons (overlay-get last 'after-string) 2) (overlay-end last))))))
        (let ((positions (nth 1 (assoc "a.txt" (roost--magit-file-lines)))))
          (should (= (nth (plist-get roost--note-box :copy) positions) (overlay-start last))))
        (roost-note-box-cancel)))))

(ert-deftest roost-a-note-box-belongs-to-the-window-it-opens-from ()
  (roost-test--with-magit-task
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (magit-diff-unstaged)
    (delete-other-windows)
    (let* ((buffer (magit-get-mode-buffer 'magit-diff-mode))
           (first (selected-window))
           ;; Above, since a box without child frames opens in the
           ;; window below.
           (second (split-window first nil 'above)))
      (set-window-buffer first buffer)
      (set-window-buffer second buffer)
      (select-window first)
      (with-current-buffer buffer
        (roost-test--goto-line-text "new line")
        (save-current-buffer (roost-note))
        (should (eq (plist-get roost--note-box :window) first))
        ;; The box is set aside for a note from the other window.
        (select-window second)
        (roost-test--goto-line-text "line 4")
        (save-current-buffer (roost-note))
        (should (eq (plist-get roost--note-box :window) second))
        (roost-note-box-cancel)))))

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

(ert-deftest roost-magit-status-lists-the-commits-to-review ()
  ;; A task branch has no upstream, so Magit showed only recent commits,
  ;; and the work an agent committed had no place in the status.
  (roost-test--with-magit-task
    (call-process "git" nil nil nil "branch" "-M" "main")
    (call-process "git" nil nil nil "checkout" "-qb" "task")
    (magit-status-setup-buffer dir)
    (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
      (should-not (string-match-p "^Unmerged into main" (buffer-string))))
    (roost-test--write-lines "a.txt" (number-sequence 1 10) "new line\n")
    (call-process "git" nil nil nil "commit" "-qam" "Add a line")
    (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
      (magit-refresh-buffer)
      (goto-char (point-min))
      (re-search-forward "^Unmerged into main")
      (let ((section (magit-current-section)))
        (should (eq (eieio-oref section 'type) 'unpushed))
        (should (equal (eieio-oref section 'value) "main.."))
        (should (= (length (eieio-oref section 'children)) 1))
        ;; RET on the heading shows the task's changes since it left main.
        (should (equal (magit-diff--dwim) "main...")))
      (should (string-match-p "Add a line" (buffer-string))))
    (let ((roost-magit-status-sections nil))
      (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
        (magit-refresh-buffer)
        (should-not (string-match-p "^Unmerged into main" (buffer-string)))))))

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
              (should (eq (key-binding "'") #'roost-goto-note))
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

(ert-deftest roost-terminal-size-is-the-window-the-task-opens-in ()
  (roost-test--isolated
   (save-window-excursion
     (delete-other-windows)
     (let* ((small (selected-window))
            (large (split-window small 20 'right)))
       (cl-letf (((symbol-function 'roost--workspace-backend) (lambda () nil)))
         ;; Without workspaces a task opens in the selected window, even when
         ;; another is larger.
         (select-window small)
         (should (= (alist-get 'width (roost--terminal-size))
                    (window-max-chars-per-line small)))
         (select-window large)
         (should (= (alist-get 'width (roost--terminal-size))
                    (window-max-chars-per-line large))))
       ;; In a workspace of its own it fills the main area.
       (cl-letf (((symbol-function 'roost--workspace-backend) (lambda () 'tab-bar)))
         (select-window small)
         (should (> (alist-get 'width (roost--terminal-size))
                    (window-max-chars-per-line large))))))))
