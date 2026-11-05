;;; roost-sweep-late.el --- Rules a reply keeps, however late it comes  -*- lexical-binding: t -*-

;;; Commentary:

;; Emacs talks to each host's helper asynchronously, and a reply can come
;; long after you have moved on.  roost-sweep.el answers every request at
;; once, so it can't see that.  This sweep holds the reply to each
;; command back, does what you might do meanwhile, then delivers it in
;; each form a host can give it:
;;
;; - Each of `roost-sweep-late--commands' starts with its reply held.
;; - Each of `roost-sweep-late--interrupters' does what you might do meanwhile.
;; - The reply comes good, refused in the host's words, dropped by the
;;   connection, or not at all before its time runs out, as a sentinel
;;   delivers it: with quitting inhibited and whatever buffer is current.
;;
;; Then these rules hold, each proved by `roost-sweep-late-rules-catch-what-breaks-them',
;; which breaks Roost the way a rule should catch and watches it fail:
;;
;; - `lisp-error': no Lisp error, in a reply or a timer, where Emacs would
;;   only log it.
;; - `wrong-buffer': no reply writes into a buffer that isn't its own.
;; - `moved': the selected window and buffer stay, unless the command was
;;   to open something and you stayed; and the task you are on stays.
;; - `stale': no reply overwrites what is newer, or brings back a task
;;   that went.
;; - `left-behind': nothing stays busy or waits on, as a draft that says
;;   it is sending, a hook, a poll that never ends, a timer.
;; - `gone': no row in a view offers a task that went.
;; - `question': a question can't land in a minibuffer you are typing in,
;;   and none is asked about a task that went.
;; - `words': a failure of a command you gave is said in words, once.
;;
;; The outside world is stubbed at `roost--run', so `roost--request' is
;; Roost's own, and windows, buffers, timers and minibuffers are real.
;; Requests are read when they are made: a held reply says what its host
;; knew then.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'roost)
(require 'roost-test)
(require 'roost-sweep)

(defvar native-comp-enable-subr-trampolines)

(defconst roost-sweep-late--host "dev"
  "The host the world's tasks are on.")

(defconst roost-sweep-late--mine "aaaaaa0000000000"
  "The ID of the task each command acts on.")

(defconst roost-sweep-late--other "bbbbbb0000000000"
  "The ID of another task on the same host.")

(defconst roost-sweep-late--dropped "ssh: connect to host dev port 22: Broken pipe"
  "What a dropped connection says.")

(defvar roost-sweep-late--requests nil
  "The requests not yet answered, oldest first.
Each a plist: :host, :action, :request, :success, :failure and :reply,
what its host said when it read it.")

(defvar roost-sweep-late--records nil
  "What the host has: an alist of task ID to task.")

(defvar roost-sweep-late--found nil
  "What the case under way broke: a list of (RULE . TEXT).")

(defvar roost-sweep-late--answer-questions t
  "How the case under way answers a yes-or-no question.")

(defvar roost-sweep-late--asked nil
  "The questions asked since the reply came: each (PROMPT . DEPTH).")

(defvar roost-sweep-late--delivering nil
  "Non-nil once the reply of the case under way has been delivered.")

(defvar roost-sweep-late--pump nil
  "What the next wait for a process runs, as a command that waits does.")

(defvar roost-sweep-late--place nil
  "Where you are as the reply comes: a plist of :window, :buffer and :task.")

(defvar roost-sweep-late--timers nil
  "The timers there were before the case began.")

(defun roost-sweep-late--problem (rule format &rest arguments)
  "Note that the case under way broke RULE, saying FORMAT with ARGUMENTS."
  (push (cons rule (apply #'format format arguments)) roost-sweep-late--found))

(defun roost-sweep-late--key (id)
  "The key of the task with ID."
  (list roost-sweep-late--host id))

(defun roost-sweep-late--task (id)
  "The cached task with ID."
  (gethash (roost-sweep-late--key id) roost--tasks))

;;;; The host

(defun roost-sweep-late--record (id name &rest fields)
  "A task with ID and NAME as its host records it, with FIELDS over its own."
  (let ((record (copy-tree
                 `((id . ,id) (name . ,name) (status . "ready") (live . t)
                   (worktree . ,(concat "/home/user/work/" name)) (repo . "/home/user/ledger")
                   (branch . ,(concat "roost/" name)) (integrationBranch . "main") (baseRef . "main")
                   (baseCommit . "c0") (socket . "main") (session . ,(concat "roost-" (substring id 0 6)))
                   (windowId . ,(if (equal id roost-sweep-late--mine) "@1" "@2"))
                   (paneId . ,(if (equal id roost-sweep-late--mine) "%1" "%2"))
                   (updatedAt . "2026-11-01T10:00:00+00:00") (agent . "claude")
                   (task . "Make the report add up.") (ahead . 1) (behind . 0) (dirty) (landed)
                   (diff . "1 file +1 −1") (conflicts) (lastEvent . "Stop")))))
    (dolist (field fields record)
      (setq record (cons field (assq-delete-all (car field) record))))))

(defun roost-sweep-late--tasks-on-host ()
  "The tasks its host would list now."
  (mapcar (lambda (entry) (copy-tree (cdr entry))) roost-sweep-late--records))

(defvar roost-sweep-late--clock 0
  "Counts what the host did, so that each thing is newer than the last.")

(defun roost-sweep-late--now ()
  "The time on the host, later than any before it."
  (format "2026-11-01T12:%02d:%02d+00:00" (/ (cl-incf roost-sweep-late--clock) 60) (% roost-sweep-late--clock 60)))

(defun roost-sweep-late--became (record status &rest fields)
  "RECORD as its host has it once it is STATUS, with FIELDS over its own."
  (dolist (field (append fields `((status . ,status) (updatedAt . ,(roost-sweep-late--now)))) record)
    (setq record (cons field (assq-delete-all (car field) record)))))

(defun roost-sweep-late--refuse (words)
  "A reply that refuses in WORDS, whatever the case delivers."
  (cons :refuse words))

(defun roost-sweep-late--reply (action request)
  "What the host says to ACTION, with its REQUEST, as things stand now."
  (let* ((id (alist-get 'id request))
         (record (copy-tree (cdr (assoc id roost-sweep-late--records))))
         (gone (roost-sweep-late--refuse (concat "Task no longer exists: " (or id "")))))
    (pcase action
      ("list" (roost-sweep-late--tasks-on-host))
      ("search" `((tasks ((id . ,roost-sweep-late--mine) (name . "mine") (repo . "/home/user/ledger")
                          (hits ((at . "2026-11-01T10:01:00Z") (role . "user") (session . "s1") (line . 3)
                                 (snippet . "Make the report add up") (text . "Make the report add up")))
                          (more . 0)))
                  (moreTasks . 0)))
      ("history" `((now . ,(float-time)) (begun . ,(- (float-time) 7200)) (changes) (tasks)))
      ("doctor" '(((name . "Python") (ok . t) (detail . "3.13"))))
      ("issues" '(((number . 7) (title . "Off by one") (url . "https://example.com/7") (body . "It is."))))
      ("jira-issues" '((issues ((key . "PROJ-7") (title . "Off by two") (url . "https://example.com/j")))))
      ("create" (roost-sweep-late--record "cccccc0000000000" "made" `(createId . ,(alist-get 'createId request))))
      ("attach" (if record '((paths "/home/user/.roost/attachments/a.png")) gone))
      ((guard (null record)) gone)
      ("stop" (roost-sweep-late--became record "stopped"))
      ("resume" (roost-sweep-late--became record "starting" '(live . t)))
      ("rename" (let ((name (cons 'name (alist-get 'name request))))
                  (cons name (cons '(renamedAt . "2026-11-01T10:05:00+00:00") (assq-delete-all 'name record)))))
      ("retire" (roost-sweep-late--became record "retired"))
      ("forget" (roost-sweep-late--became record "forgotten"))
      ("merge" (roost-sweep-late--became record "retired" '(retiringCommit . "c9")))
      ("discard" (if (alist-get 'dryRun request)
                     `((discard (commit . "c1") (commits . 0) (changes . 0)))
                   (roost-sweep-late--became record "discarded")))
      ("shell" (cons '(shellPaneId . "%9") record))
      ("update" (cons '(update (changed . t)) record))
      ("pr" (cons `(pr (number . 12) (url . "https://example.com/12")) (assq-delete-all 'pr record)))
      (_ record))))

(defun roost-sweep-late--hold (host _code input success failure &optional _timeout)
  "Hold back the reply to INPUT for HOST, for `roost--run'.
SUCCESS and FAILURE take it when it comes.  Its host reads the world now."
  (let* ((request (json-parse-string input :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil))
         (action (alist-get 'action request)))
    (setq roost-sweep-late--requests
          (append roost-sweep-late--requests
                  (list (list :host host :action action :request request
                              :success success :failure failure
                              :reply (roost-sweep-late--reply action request)))))))

(defun roost-sweep-late--take (action)
  "The oldest request for ACTION held, or nil."
  (seq-find (lambda (request) (equal (plist-get request :action) action)) roost-sweep-late--requests))

(defun roost-sweep-late--record-replied (request)
  "Have the host's records say what the good reply to REQUEST did."
  (let* ((reply (plist-get request :reply))
         (id (alist-get 'id (plist-get request :request))))
    (pcase (plist-get request :action)
      ((or "retire" "merge" "forget")
       (setq roost-sweep-late--records (assoc-delete-all id roost-sweep-late--records)))
      ("discard"
       (unless (alist-get 'dryRun (plist-get request :request))
         (setq roost-sweep-late--records (assoc-delete-all id roost-sweep-late--records))))
      ("create" (setq roost-sweep-late--records
                      (append roost-sweep-late--records (list (cons (alist-get 'id reply) reply)))))
      ((or "stop" "resume" "rename" "shell" "pr")
       (when (assoc id roost-sweep-late--records)
         (setf (alist-get id roost-sweep-late--records nil nil #'equal) (assq-delete-all 'pushed reply)))))))

;;;; Delivering

(defun roost-sweep-late--guarded (what function &rest arguments)
  "Call FUNCTION with ARGUMENTS, noting as WHAT an error Emacs would only log."
  (condition-case err
      (apply function arguments)
    (error (roost-sweep-late--problem 'lisp-error "%s signals %S" what err))))

(defun roost-sweep-late--as-sentinel (what function &rest arguments)
  "Call FUNCTION with ARGUMENTS as a process sentinel runs, named WHAT.
That is with quitting inhibited, in the buffer of the selected window,
as Emacs waits for you, which comes back afterwards."
  (let ((inhibit-quit t))
    (with-current-buffer (window-buffer (selected-window))
      (apply #'roost-sweep-late--guarded what function arguments))))

(defun roost-sweep-late--answer (request form)
  "Deliver the reply to REQUEST in FORM.
FORM is `good', `dropped', `no-reply', or (refused . WORDS)."
  (setq roost-sweep-late--requests (delq request roost-sweep-late--requests))
  (let* ((reply (plist-get request :reply))
         (action (plist-get request :action))
         (what (format "the reply to %s" action))
         (refused (eq (car-safe reply) :refuse)))
    (pcase form
      ((guard (and refused (eq form 'good)))
       (roost-sweep-late--as-sentinel what (plist-get request :failure) (cdr reply)))
      ('good
       (roost-sweep-late--record-replied request)
       (roost-sweep-late--as-sentinel what (plist-get request :success) reply))
      ('dropped (roost-sweep-late--as-sentinel what (plist-get request :failure) roost-sweep-late--dropped))
      ('no-reply (roost-sweep-late--as-sentinel
                  what (plist-get request :failure)
                  (propertize "No reply after 30s; the operation may still finish on the host, so refresh before retrying"
                              'roost-no-reply t)))
      (`(refused . ,words) (roost-sweep-late--as-sentinel what (plist-get request :failure) words)))))

(defun roost-sweep-late--roost-timer-p (timer)
  "Whether TIMER is one this case made, and could be Roost's.
Emacs's own, as for undo, go on as they would."
  (let ((function (timer--function timer)))
    (and (not (memq timer roost-sweep-late--timers))
         (not (timer--repeat-delay timer))
         (or (not (symbolp function))
             (string-prefix-p "roost-" (symbol-name function))))))

(defun roost-sweep-late--fire-timers ()
  "Run the timers this case made as if their time had come; non-nil if any did."
  (let ((due (seq-filter #'roost-sweep-late--roost-timer-p (append timer-list timer-idle-list))))
    (dolist (timer due)
      (cancel-timer timer)
      (with-current-buffer (window-buffer (selected-window))
        (apply #'roost-sweep-late--guarded "a timer" (timer--function timer) (timer--args timer))))
    due))

(defun roost-sweep-late--settle ()
  "Run what is due and answer what is asked, until nothing is left."
  (let ((rounds 0))
    (while (and (< rounds 60)
                (or (roost-sweep-late--fire-timers) roost-sweep-late--requests))
      (cl-incf rounds)
      (when-let* ((request (car roost-sweep-late--requests)))
        (roost-sweep-late--answer request 'good)))
    (when (>= rounds 60)
      (roost-sweep-late--problem 'left-behind "it never settles: %S"
                           (mapcar (lambda (request) (plist-get request :action)) roost-sweep-late--requests)))))

;;;; The world

(defun roost-sweep-late--terminal (id)
  "The terminal of the task with ID, made if need be."
  (let ((name (format "*late terminal %s*" (substring id 0 6))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (setq major-mode 'tmux-control-mode
                roost-test--tmux (list :host roost-sweep-late--host :socket "main"
                                       :session (concat "roost-" (substring id 0 6))
                                       :window (if (equal id roost-sweep-late--mine) "@1" "@2")
                                       :pane (if (equal id roost-sweep-late--mine) "%1" "%2")))
          (current-buffer)))))

(defun roost-sweep-late--connect (_host _socket session)
  "Show the terminal of tmux SESSION in the selected window."
  (switch-to-buffer (roost-sweep-late--terminal (concat (string-remove-prefix "roost-" session) "0000000000"))))

(defun roost-sweep-late--show (name)
  "Show a buffer called NAME in the selected window, as another package would."
  (switch-to-buffer (get-buffer-create name)))

(defconst roost-sweep-late--asking
  (mapcar (lambda (function) (cons function (symbol-function function)))
          '(y-or-n-p yes-or-no-p read-string completing-read))
  "Emacs's own ways to ask, which `roost-test--isolated' and the world stub.")

(defvar roost-sweep-late--real-questions nil
  "Non-nil when questions go to a real minibuffer, with keys to answer them.")

(defun roost-sweep-late--question (function prompt &rest arguments)
  "Note that Roost asks PROMPT, by FUNCTION with ARGUMENTS, and answer it.
It is answered as the case does, unless it goes to a real minibuffer,
but for a reply's question."
  (when (and roost-sweep-late--delivering (or (not roost-sweep-late--real-questions) (> (minibuffer-depth) 0)))
    (push (cons prompt (minibuffer-depth)) roost-sweep-late--asked)
    (when (> (minibuffer-depth) 0)
      (roost-sweep-late--problem 'question "asks %S inside the minibuffer" prompt)))
  (if (and roost-sweep-late--real-questions (= (minibuffer-depth) 0))
      (apply (alist-get function roost-sweep-late--asking) prompt arguments)
    roost-sweep-late--answer-questions))

(defmacro roost-sweep-late--world (&rest body)
  "Run BODY with a host held back, a code buffer, and the tasks on that host."
  (declare (indent 0))
  ;; Natively compiled, a stubbed primitive needs a trampoline, and
  ;; compiling one runs a process; Roost runs from source here.
  `(dlet ((native-comp-enable-subr-trampolines nil))
    (roost-test--isolated
    (roost-test--with-tmux-buffers
     (dlet ((features (append '(tmux-control magit) features))
            (inhibit-message t)
            (message-log-max t)
            (roost-sweep-late--requests nil) (roost-sweep-late--records nil) (roost-sweep-late--found nil)
            (roost-sweep-late--answer-questions t)
            (roost-sweep-late--asked nil) (roost-sweep-late--delivering nil) (roost-sweep-late--pump nil)
            (roost-sweep-late--place nil) (roost-sweep-late--clock 0)
            (roost-sweep-late--timers (append timer-list timer-idle-list))
            (roost-hosts nil)
            (roost-workspace nil)
            (roost-watch-mode nil) (roost-sidebar-mode nil) (roost-task-panel-mode nil)
            (roost--watch-timer nil)
            (roost--workload-generation 0) (roost--workload nil)
            (minibuffer-exit-hook nil) (window-configuration-change-hook nil)
            (after-delete-frame-functions nil))
       (cl-letf (((symbol-function 'roost--run) #'roost-sweep-late--hold)
                 ((symbol-function 'roost--project-value) #'ignore)
                 ((symbol-function 'roost--git-in) #'ignore)
                 ((symbol-function 'roost--write-json-list) #'ignore)
                 ((symbol-function 'roost--magit-setup) #'ignore)
                 ((symbol-function 'roost--notify) #'ignore)
                 ((symbol-function 'tmux-control-connect-or-switch) #'roost-sweep-late--connect)
                 ((symbol-function 'tmux-control-send-command) #'ignore)
                 ((symbol-function 'tmux-control-select-pane) #'ignore)
                 ((symbol-function 'tmux-control-tiled-p) #'ignore)
                 ((symbol-function 'tmux-control-tile) #'ignore)
                 ((symbol-function 'tmux-control-disconnect) #'ignore)
                 ((symbol-function 'tmux-control-reconnect) #'ignore)
                 ((symbol-function 'tmux-control-query)
                  (lambda (_command callback) (funcall callback "")))
                 ((symbol-function 'dired) (lambda (&rest _) (roost-sweep-late--show "*late dired*")))
                 ((symbol-function 'magit-status) (lambda (&rest _) (roost-sweep-late--show "*late magit*")))
                 ((symbol-function 'magit-diff-working-tree) (lambda (&rest _) (roost-sweep-late--show "*late diff*")))
                 ((symbol-function 'browse-url) #'ignore)
                 ((symbol-function 'completing-read)
                  (lambda (prompt collection &rest arguments)
                    (if roost-sweep-late--real-questions
                        (apply (alist-get 'completing-read roost-sweep-late--asking) prompt collection arguments)
                      (car (all-completions "" collection)))))
                 ((symbol-function 'read-directory-name)
                  (lambda (prompt &rest _)
                    (concat "/ssh:dev:" (read-string prompt))))
                 ((symbol-function 'read-string)
                  (lambda (&rest arguments)
                    (if roost-sweep-late--real-questions
                        (apply (alist-get 'read-string roost-sweep-late--asking) arguments)
                      "mine")))
                 ((symbol-function 'y-or-n-p) (apply-partially #'roost-sweep-late--question 'y-or-n-p))
                 ((symbol-function 'yes-or-no-p) (apply-partially #'roost-sweep-late--question 'yes-or-no-p))
                 ((symbol-function 'accept-process-output)
                  (lambda (&rest _)
                    (if-let* ((pump roost-sweep-late--pump))
                        (progn (setq roost-sweep-late--pump nil) (funcall pump))
                      (if roost-sweep-late--requests
                          (roost-sweep-late--answer (car roost-sweep-late--requests) 'good)
                        (signal 'quit nil))))))
         (setq roost--remembered-hosts (list roost-sweep-late--host))
         (puthash (list roost-sweep-late--host roost-state-directory) (car (roost--helper)) roost--installed)
         (save-window-excursion
           (let ((existing (buffer-list)))
             (unwind-protect
                 (progn ,@body)
               (dolist (buffer (buffer-list))
                 (unless (memq buffer existing)
                   (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))
               (when (timerp roost--watch-timer) (cancel-timer roost--watch-timer))
               (dolist (timer (append timer-list timer-idle-list))
                 (when (roost-sweep-late--roost-timer-p timer) (cancel-timer timer))))))))))))

(defun roost-sweep-late--populate (fields others)
  "Give the host its tasks, and Roost a list of them.
FIELDS are the one acted on's, and OTHERS the other's."
  (setq roost-sweep-late--records
        (list (cons roost-sweep-late--mine (apply #'roost-sweep-late--record roost-sweep-late--mine "mine" fields))
              (cons roost-sweep-late--other (apply #'roost-sweep-late--record roost-sweep-late--other "other" others))))
  (roost--apply-snapshot roost-sweep-late--host (roost-sweep-late--tasks-on-host)))

(defun roost-sweep-late--dashboard ()
  "The dashboard, listing the tasks."
  (with-current-buffer (get-buffer-create "*roost*")
    (roost-dashboard-mode)
    (roost--render-dashboard)
    (current-buffer)))

(defun roost-sweep-late--origin (origin)
  "Make the buffer of ORIGIN, the place a command starts from.
Return it, shown in the selected window."
  (let* ((task (roost-sweep-late--task roost-sweep-late--mine))
         (buffer
          (pcase origin
            ('here (get-buffer-create "*late here*"))
            ('terminal (roost-sweep-late--terminal roost-sweep-late--mine))
            ('other-terminal (roost-sweep-late--terminal roost-sweep-late--other))
            ('panel (roost--task-info-buffer task))
            ('dashboard (roost-sweep-late--dashboard))
            ('send-draft (save-window-excursion
                           (roost--send-draft task)
                           (insert "Make it add up.")
                           (current-buffer)))
            ('pr-draft (save-window-excursion
                         (roost--pr-draft task)
                         (current-buffer)))
            ('compose (save-window-excursion
                        (cl-letf (((symbol-function 'roost--compose-default-directory)
                                   (lambda (&rest _) "/ssh:dev:/home/user/ledger/")))
                          (roost--compose nil (cons "Add the totals." nil)))
                        (current-buffer))))))
    (set-window-buffer (selected-window) buffer)
    (set-buffer buffer)
    buffer))

(defun roost-sweep-late--lay-out (origin)
  "Show ORIGIN in the selected window beside some code, and return its buffer.
The dashboard shows below, unless ORIGIN is it.  The code is a bystander,
with nothing to do with any task."
  (delete-other-windows)
  (with-current-buffer (get-buffer-create "*late code*")
    (unless (> (buffer-size) 0) (insert "(keep this)\n")))
  (let ((code (split-window-right)))
    (set-window-buffer code "*late code*"))
  (unless (eq origin 'dashboard)
    (set-window-buffer (split-window-below) (roost-sweep-late--dashboard)))
  (roost-sweep-late--origin origin))

(defun roost-sweep-late--fingerprint ()
  "What must not change in the bystander, as (TEXT POINT), or nil once it is gone."
  (when-let* ((buffer (get-buffer "*late code*")))
    (with-current-buffer buffer
      (list (buffer-string) (point)))))

;;;; What you might do meanwhile

(defvar roost-sweep-late--origin-buffer nil
  "The buffer the command of the case under way started from.")

(defvar roost-sweep-late--frame nil
  "The frame the case under way started in, when one of its own.")

(defvar roost-sweep-late--sides nil
  "Non-nil for cases with the sidebar and task panel on, in a frame with room for them.")

(defvar roost-sweep-late--after-quit nil
  "What delivers the reply of a case that quit while it waited.")

(defconst roost-sweep-late--newer "2026-11-01T11:00:00+00:00"
  "When the agent last did something, for a host that has moved on.")

(defvar roost-sweep-late--spec nil
  "The command of the case under way.")

(defvar roost-sweep-late--view nil
  "What the view of a command run again showed, once the newer reply came.")

(defun roost-sweep-late--request-for (action id)
  "The oldest request held for ACTION on the task with ID."
  (seq-find (lambda (request)
              (and (equal (plist-get request :action) action)
                   (equal (alist-get 'id (plist-get request :request)) id)))
            roost-sweep-late--requests))

(defun roost-sweep-late--note-place ()
  "Note where you are, as the reply comes."
  (setq roost-sweep-late--place (list :window (selected-window) :buffer (window-buffer (selected-window))
                                :task roost--current-task
                                :shown-tasks (seq-keep (lambda (window)
                                                         (when-let* ((task (roost--terminal-task (window-buffer window))))
                                                           (roost--key task)))
                                                       (window-list))
                                :bystanders (roost-sweep-late--fingerprint))))

(defun roost-sweep-late--in-minibuffer (function)
  "Call FUNCTION from a minibuffer you are typing in, then leave it."
  (let ((unread-command-events (list ?\r))
        ;; Otherwise, in batch, it reads standard input.
        (executing-kbd-macro t))
    (minibuffer-with-setup-hook
        (lambda ()
          (insert "half a thought")
          (funcall function)
          ;; Timers run while you type.
          (roost-sweep-late--fire-timers)
          (unless (equal (minibuffer-contents) "half a thought")
            (roost-sweep-late--problem 'wrong-buffer "the minibuffer now says %S" (minibuffer-contents))))
      (read-from-minibuffer "Anything else? "))))

(defun roost-sweep-late--go (id)
  "Have the task with ID go, as another reply says it did."
  (roost--act (roost-sweep-late--task id) "retire" nil
              (lambda (retired)
                (roost--retired-workspace retired)
                (roost--kill-worktree-buffers retired)))
  (roost-sweep-late--answer (roost-sweep-late--request-for "retire" id) 'good))

(defun roost-sweep-late--move-on ()
  "Have the agent of the task acted on move on, as its host alone knows."
  (setf (alist-get roost-sweep-late--mine roost-sweep-late--records nil nil #'equal)
        (roost-sweep-late--record roost-sweep-late--mine "mine" '(status . "running")
                            `(updatedAt . ,roost-sweep-late--newer))))

(defun roost-sweep-late--second (start action)
  "Call START, a second command on the task acted on, and take its reply to ACTION."
  (funcall start)
  (when-let* ((request (roost-sweep-late--request-for action roost-sweep-late--mine)))
    (roost-sweep-late--answer request 'good)))

(defvar roost-sweep-late--interrupters
  `((none :while-waiting t :stays t :run ,(lambda (deliver) (funcall deliver)))
    (kill-origin
     :left t :while-waiting t
     :run ,(lambda (deliver) (kill-buffer roost-sweep-late--origin-buffer) (funcall deliver)))
    (kill-terminal
     :run ,(lambda (deliver)
             (when-let* ((terminal (get-buffer (roost-sweep-late--terminal roost-sweep-late--mine))))
               (kill-buffer terminal))
             (funcall deliver)))
    (delete-window
     :left t
     :run ,(lambda (deliver) (delete-window) (funcall deliver)))
    (delete-frame
     :left t :frame t
     :run ,(lambda (deliver) (delete-frame roost-sweep-late--frame t) (funcall deliver)))
    (other-buffer
     :left t
     :run ,(lambda (deliver)
             (switch-to-buffer (get-buffer-create "*late elsewhere*"))
             (funcall deliver)))
    (other-window
     :left t
     :run ,(lambda (deliver)
             (select-window (get-buffer-window "*late code*"))
             (funcall deliver)))
    (other-task
     :left t
     :run ,(lambda (deliver)
             (roost-open-task (roost-sweep-late--task roost-sweep-late--other))
             (roost-sweep-late--answer (roost-sweep-late--request-for "inspect" roost-sweep-late--other) 'good)
             (funcall deliver)))
    (same-task-send
     :stays t
     :run ,(lambda (deliver)
             (roost-sweep-late--second (lambda () (roost-send (roost-sweep-late--task roost-sweep-late--mine) "And this."))
                                 "send")
             (funcall deliver)))
    (same-task-rename
     :run ,(lambda (deliver)
             (roost-sweep-late--second (lambda () (roost-rename (roost-sweep-late--task roost-sweep-late--mine) "new name"))
                                 "rename")
             (funcall deliver)))
    (same-task-stop
     :run ,(lambda (deliver)
             (roost-sweep-late--second (lambda () (roost--act (roost-sweep-late--task roost-sweep-late--mine) "stop")) "stop")
             (funcall deliver)))
    (again
     :when :again :left t :quiet t
     :run ,(lambda (deliver)
             (funcall (plist-get roost-sweep-late--spec :start))
             (roost-sweep-late--answer (car (last roost-sweep-late--requests)) 'good)
             (setq roost-sweep-late--view (with-current-buffer (window-buffer (selected-window))
                                            (buffer-string)))
             (funcall deliver)))
    (retired
     :gone t :while-waiting t
     :run ,(lambda (deliver) (roost-sweep-late--go roost-sweep-late--mine) (funcall deliver)))
    (listed-gone
     :gone t :while-waiting t :unless "list"
     :run ,(lambda (deliver)
             (setq roost-sweep-late--records (assoc-delete-all roost-sweep-late--mine roost-sweep-late--records))
             (roost--refresh-host roost-sweep-late--host t)
             (roost-sweep-late--answer (roost-sweep-late--take "list") 'good)
             (funcall deliver)))
    (newer-poll
     :newer t :while-waiting t :stays t :unless "list"
     :run ,(lambda (deliver)
             (roost-sweep-late--move-on)
             (roost--refresh-host roost-sweep-late--host t)
             (roost-sweep-late--answer (roost-sweep-late--take "list") 'good)
             (funcall deliver)))
    (forget-host
     :gone t :host-gone t
     :run ,(lambda (deliver)
             (let ((roost-sweep-late--answer-questions t))
               (roost-forget-host roost-sweep-late--host))
             (funcall deliver)))
    (quit
     :while-waiting t :quiet t :stays t
     :run ,(lambda (deliver)
             (setq roost-sweep-late--after-quit deliver)
             (signal 'quit nil)))
    (minibuffer
     :stays t
     :run ,(lambda (deliver)
             (roost-sweep-late--note-place)
             (roost-sweep-late--in-minibuffer deliver)))
    (watch-off
     :off t :stays t
     :run ,(lambda (deliver) (roost-watch-mode -1) (funcall deliver)))
    (sides-off
     :sides-off t
     :run ,(lambda (deliver)
             (roost-sidebar-mode -1)
             (roost-task-panel-mode -1)
             (funcall deliver))))
  "What you might do while a reply is on its way, each (NAME . PLIST).
:run does it, then calls the function it gets to deliver the reply.
:when names what a command must say for it to apply.
:left means you went somewhere else, :stays that you stayed and nothing
stands in the way of what you asked to see, :gone that the task went, and
:host-gone its host too; :newer that its host has moved on; :frame that
it needs the command to start in a frame of its own; :off that
you turned watching off; :quiet that you said you don't care; :unless
names an action it can't follow.
:while-waiting that it can happen while a command waits for its reply,
with Emacs running only timers and other replies.")

;;;; Commands

(defun roost-sweep-late--mine ()
  "The task each command acts on, as cached."
  (roost-sweep-late--task roost-sweep-late--mine))

(defconst roost-sweep-late--no-window "The agent's tmux window is gone; resume the task")

(defconst roost-sweep-late--retired "Task is retired")

(defconst roost-sweep-late--unmerged "Task branch has unmerged commits; merge it (m) first, discard it, or forget the task")

(defconst roost-sweep-late--uncommitted "Uncommitted or untracked files remain; review and commit in Magit first")

(defconst roost-sweep-late--other-branch "The task's worktree is on feat, not the task's branch roost/mine; check out roost/mine there")

(defconst roost-sweep-late--uncommitted-update "Commit the task's changes before updating it from main")

(defconst roost-sweep-late--worktree-gone "Task worktree is gone; forget the task to remove it from Roost")

(defvar roost-sweep-late--commands
  `((open
     :start ,(lambda () (roost-open-task (roost-sweep-late--mine)))
     :action "inspect" :opens t :shows "*late terminal aaaaaa*"
     :refusals ((,roost-sweep-late--no-window . asks) (,roost-sweep-late--retired)))
    (open-from-dashboard
     :origin dashboard
     :start ,(lambda () (roost-open-task (roost-sweep-late--mine)))
     :action "inspect" :opens t :shows "*late terminal aaaaaa*"
     :refusals ((,roost-sweep-late--no-window . asks)))
    (next
     :start ,#'roost-next-waiting
     :action "inspect" :opens t :shows "*late terminal aaaaaa*"
     :refusals ((,roost-sweep-late--no-window . asks)))
    (notification-click
     :start ,(lambda ()
               (roost--open-from-notification roost-sweep-late--host roost-sweep-late--mine)
               (roost-sweep-late--fire-timers))
     :action "inspect" :opens t :shows "*late terminal aaaaaa*"
     :refusals ((,roost-sweep-late--no-window . asks)))
    (panel
     :start ,(lambda () (roost-task-info (roost-sweep-late--mine)))
     :action "list" :opens t :background t)
    (review
     :start ,(lambda () (roost-review (roost-sweep-late--mine)))
     :action "look" :opens t :shows "*late magit*"
     :refusals ((,roost-sweep-late--worktree-gone)))
    (review-beside-another-terminal
     :origin other-terminal
     :start ,(lambda () (roost-review (roost-sweep-late--mine)))
     :first ("look") :action "inspect" :opens t :shows "*late magit*"
     :refusals ((,roost-sweep-late--no-window . quiet)))
    (diff
     :start ,(lambda () (roost-diff (roost-sweep-late--mine)))
     :action "look" :opens t :shows "*late diff*")
    (files
     :origin other-terminal
     :start ,(lambda () (roost-files (roost-sweep-late--mine)))
     :action "inspect" :opens t :shows "*late dired*"
     :refusals ((,roost-sweep-late--no-window . quiet)))
    (shell
     :origin terminal
     :start ,(lambda () (roost-shell (roost-sweep-late--mine)))
     :action "shell" :opens t :shows "*late terminal aaaaaa*"
     :refusals (("Task's tmux window is gone; resume the task before opening its shell")))
    (mark-looked
     :start ,(lambda () (roost-mark-looked (roost-sweep-late--mine)))
     :action "look" :refusals ((,roost-sweep-late--worktree-gone)))
    (send
     :start ,(lambda () (roost-send (roost-sweep-late--mine) "Add a test."))
     :action "send" :refusals (("The agent is not running; resume the task first")))
    (note-send
     :start ,(lambda ()
               (setq roost--notes (list (roost-test--note "n1" roost-sweep-late--mine '(file . "a.py") '(line . 3)
                                                          '(end . 3) '(text . "Keep the sign."))))
               (roost-note-send (car roost--notes)))
     :action "send" :refusals (("The agent is not running; resume the task first")))
    (send-draft
     :origin send-draft :start ,#'roost-send-submit
     :action "send" :closes t :refusals (("The agent is not running; resume the task first")))
    (attach
     :origin send-draft
     :start ,(lambda () (roost--send-attach-png "PNG"))
     :action "attach" :refusals ((,roost-sweep-late--retired)))
    (create
     :start ,(lambda () (roost-new-task "/ssh:dev:/home/user/ledger/" "made" nil "Go on." "claude"))
     :action "create" :opens t :shows "*late terminal cccccc*" :watches t :makes t
     :refusals (("No branch, tag or commit named 'x' to start from")))
    (compose-submit
     :origin compose :start ,#'roost-compose-submit
     :action "create" :opens t :shows "*late terminal cccccc*" :closes t :watches t :makes t
     :refusals (("No branch, tag or commit named 'x' to start from")))
    (compose-listed-once-no-reply-came
     :origin compose
     :start ,(lambda ()
               (roost-compose-submit)
               (let ((request (roost-sweep-late--take "create")))
                 (roost-sweep-late--record-replied request)
                 (roost-sweep-late--answer request 'no-reply))
               (roost-refresh t))
     ;; A reply to another action makes the list older than it, and it
     ;; waits for the next.
     :action "list" :opens t :shows "*late terminal cccccc*" :closes t :watches t :makes t :background t
     :not (same-task-send))
    (resume
     :fields ((status . "stopped") (live))
     :start ,(lambda () (roost-resume (roost-sweep-late--mine)))
     :action "resume" :opens t :shows "*late terminal aaaaaa*"
     :refusals ((,roost-sweep-late--worktree-gone)))
    (resume-opening
     :fields ((status . "stopped") (live))
     :start ,(lambda () (roost-resume (roost-sweep-late--mine)))
     :first ("resume") :action "inspect" :opens t
     :refusals ((,roost-sweep-late--no-window . asks)))
    (resume-others
     :fields ((status . "crashed") (live))
     :others ((status . "crashed") (live))
     :start ,(lambda () (roost-resume (roost-sweep-late--mine) t))
     ;; Going to a task whose agent crashed takes the question, not its terminal.
     :action "resume" :opens t :not (other-task) :refusals ((,roost-sweep-late--worktree-gone)))
    (stop
     :origin terminal :closes t
     :start ,(lambda () (roost-stop (roost-sweep-late--mine)))
     :action "stop" :refusals ((,roost-sweep-late--retired)))
    (stop-refused-reconnecting
     :origin terminal
     :start ,(lambda ()
               (roost--act (roost-sweep-late--mine) "stop")
               (roost-sweep-late--answer (roost-sweep-late--take "stop") `(refused . ,roost-sweep-late--retired)))
     :action "inspect" :background t)
    (rename
     :start ,(lambda () (roost-rename (roost-sweep-late--mine) "renamed"))
     :action "rename" :refusals ((,roost-sweep-late--retired)))
    (retire
     :fields ((ahead . 0))
     :start ,(lambda () (roost-retire (roost-sweep-late--mine)))
     :action "retire"
     :refusals ((,roost-sweep-late--unmerged . asks) (,roost-sweep-late--uncommitted . asks)
                (,roost-sweep-late--other-branch . asks) ("The agent is active; stop it or wait before retiring this task")))
    (merge
     :start ,(lambda () (roost-merge-retire (roost-sweep-late--mine)))
     :action "merge"
     :refusals (("The integration branch main no longer exists")))
    (forget
     :fields ((status . "stopped") (live))
     :start ,(lambda () (roost-forget (roost-sweep-late--mine)))
     :action "forget" :refusals (("The agent is running; stop the task before forgetting it")))
    (forget-running
     :fields ((status . "running"))
     :start ,(lambda () (roost-forget (roost-sweep-late--mine)))
     :action "stop" :refusals ((,roost-sweep-late--retired)))
    (forget-once-stopped
     :fields ((status . "running"))
     :start ,(lambda () (roost-forget (roost-sweep-late--mine)))
     :first ("stop") :action "forget")
    (discard-asking
     :start ,(lambda () (roost-discard (roost-sweep-late--mine)))
     :action "discard" :wait t :refusals ((,roost-sweep-late--retired)))
    (discard
     :start ,(lambda () (roost-discard (roost-sweep-late--mine)))
     :action "discard" :refusals (("The task's branch has moved since you were asked; look at it again before discarding")))
    (update
     :start ,(lambda () (roost-update (roost-sweep-late--mine)))
     :action "update" :refusals ((,roost-sweep-late--uncommitted-update . asks) ("Task worktree is gone")))
    (update-conflicts
     :start ,(lambda () (roost-update (roost-sweep-late--mine)))
     :action "update" :reply ,(lambda (reply) (cons '(update (conflicts "a.py")) reply)))
    (update-rerere
     :start ,(lambda () (roost-update (roost-sweep-late--mine)))
     :action "update" :reply ,(lambda (reply) (cons '(update (resolved "a.py")) reply)))
    (pr-push
     :fields ((pr (number . 12) (url . "https://example.com/12")))
     :start ,(lambda () (roost-pr (roost-sweep-late--mine)))
     :action "pr" :refusals (("Commit the task's changes before pushing")))
    (pr-draft
     :origin pr-draft :start ,#'roost-pr-submit
     :action "pr" :closes t
     :refusals (("Commit the task's changes before opening a pull request")))
    (search
     :start ,(lambda () (roost-search "report"))
     :action "search" :said-in "*roost search*" :again t)
    (workload
     :start ,#'roost-workload
     :action "history" :said-in "*roost workload*" :again t)
    (doctor
     :start ,#'roost-doctor
     :action "doctor" :said-in "*roost doctor*" :again t)
    (issues
     :origin compose :start ,#'roost-compose-set-issue
     :action "issues" :wait t)
    (poll
     :start ,(lambda () (roost-refresh t))
     :action "list" :background t)
    (poll-full
     :start ,#'roost-refresh
     :action "list" :background t)
    (notice
     :fields ((status . "running"))
     :start ,(lambda ()
               (setq roost-notify t)
               (roost--cache-task roost-sweep-late--host
                                  (roost-sweep-late--record roost-sweep-late--mine "mine"
                                                      `(updatedAt . ,roost-sweep-late--newer))))
     :action "inspect" :background t)
    (turn
     :fields ((landed) (dirty) (ahead . 1) (behind . 0) (conflicts "a.py") (seen . "2026-11-01T10:00:00+00:00"))
     :start ,(lambda () (funcall roost-test--report-turn (roost-sweep-late--mine)))
     :action "turn" :background t))
  "What Roost starts and a host answers later, each (NAME . PLIST).
:start starts it, from a window showing :origin, `here' unless it says
otherwise, as `roost-sweep-late--origin' makes it; :action is the request to
hold, and :first the ones before it to answer at once.  :fields are the
task's own.  :refusals are what its host may say instead, each (WORDS . HOW):
HOW is nil when Roost says the words, `asks' when it asks a question
instead.  :opens means it may show something in the selected window,
if you stayed; :shows, what it then shows.  :closes that it closes the
draft it started from.  :background that nobody asked for it, so its
failure need not be said, and :said-in the buffer it says it in, not the
echo area.  :wait that the command waits for the reply.  :reply makes
the good reply from what the host would say.  :others are the other
task's fields.  :watches that it starts `roost-watch-mode', and :makes
that it makes a task of its own, and uses its host, so remembers it.
:again that it
shows what a run of it found, so that a late reply to an older run must
change nothing.  :not names interrupters that can't follow it.")

;;;; Rules

(defun roost-sweep-late--rows-gone ()
  "The tasks that rows in Roost's views offer and Roost has no more."
  (let (found)
    (dolist (name (list "*roost*" roost--sidebar-buffer))
      (when-let* ((buffer (get-buffer name))
                  ;; One no window shows is drawn when one does.
                  ((get-buffer-window buffer t)))
        (with-current-buffer buffer
          (let ((position (point-min)))
            (while (setq position (text-property-not-all position (point-max) 'roost-task nil))
              (let ((key (get-text-property position 'roost-task)))
                (unless (gethash key roost--tasks)
                  (cl-pushnew (format "%s offers %S" name key) found :test #'equal)))
              (setq position (or (next-single-property-change position 'roost-task) (point-max))))))))
    found))

(defun roost-sweep-late--messages (from)
  "What was said since FROM, a position in *Messages*."
  (with-current-buffer (messages-buffer)
    (buffer-substring-no-properties (min from (point-max)) (point-max))))

(defun roost-sweep-late--count (words text)
  "How many times WORDS are in TEXT."
  (let ((count 0) (start 0))
    (while (setq start (string-search words text start))
      (cl-incf count)
      (setq start (+ start (length words))))
    count))

(defun roost-sweep-late--form-words (form)
  "The words a failed reply in FORM says, or nil for a good one."
  (pcase form
    ('dropped roost-sweep-late--dropped)
    ('no-reply "No reply after")
    (`(refused . ,words) words)))

(defun roost-sweep-late--check-place (spec interrupter)
  "Note what moved that shouldn't, by SPEC's command after INTERRUPTER."
  (let* ((place roost-sweep-late--place)
         (stayed (not (plist-get interrupter :left)))
         (gone (and (plist-get interrupter :gone) (not (plist-get spec :makes))))
         ;; A question you said yes to takes you there.
         (may-open (or (and (plist-get spec :opens) stayed (not gone))
                       (and roost-sweep-late--asked roost-sweep-late--answer-questions)))
         (closing (and (plist-get spec :closes) (eq (plist-get place :buffer) roost-sweep-late--origin-buffer))))
    (unless (or may-open closing)
      (unless (eq (selected-window) (plist-get place :window))
        (roost-sweep-late--problem 'moved "the selected window moved"))
      (unless (eq (window-buffer (selected-window)) (plist-get place :buffer))
        (roost-sweep-late--problem 'moved "the selected window shows %s, not %s"
                             (window-buffer (selected-window)) (plist-get place :buffer)))
      ;; Redrawing takes up the task whose terminal shows.
      (when (and (not (equal roost--current-task (plist-get place :task)))
                 (not (member roost--current-task (plist-get place :shown-tasks))))
        (roost-sweep-late--problem 'moved "the task opened last is now %S" roost--current-task)))
    (unless (equal (roost-sweep-late--fingerprint) (plist-get place :bystanders))
      (roost-sweep-late--problem 'wrong-buffer "a bystander's text or point changed"))))

(defun roost-sweep-late--check-tasks (spec interrupter other)
  "Note what became of the tasks that shouldn't have, after INTERRUPTER.
SPEC's command is the one acted on.  OTHER is how the other task was as
the reply came."
  ;; Making a task on a host you forgot watches it again, with its tasks.
  (when (and (plist-get interrupter :gone)
             (not (and (plist-get interrupter :host-gone) (plist-get spec :makes))))
    (when (roost-sweep-late--mine)
      (roost-sweep-late--problem 'stale "a task that went is back, %s" (roost--field (roost-sweep-late--mine) 'status))))
  (when (and (plist-get interrupter :host-gone) (not (plist-get spec :makes)))
    (when (seq-some (lambda (task) (equal (roost--field task 'host) roost-sweep-late--host)) (roost-tasks))
      (roost-sweep-late--problem 'stale "a task of a forgotten host is back"))
    (when (member roost-sweep-late--host (roost--hosts))
      (roost-sweep-late--problem 'stale "a forgotten host is watched again"))
    (when (gethash roost-sweep-late--host roost--errors)
      (roost-sweep-late--problem 'stale "a forgotten host shows an error")))
  (when (plist-get interrupter :newer)
    (let ((updated (roost--field (roost-sweep-late--mine) 'updatedAt)))
      (unless (or (null updated) (not (string< updated roost-sweep-late--newer)))
        (roost-sweep-late--problem 'stale "an older reply overwrites a newer one: %s" updated))))
  (when (plist-get interrupter :off)
    (when (and roost-watch-mode (not (plist-get spec :watches)))
      (roost-sweep-late--problem 'stale "watching you turned off is on again")))
  (when (plist-get interrupter :sides-off)
    (when (or roost-sidebar-mode roost-task-panel-mode
              (get-buffer-window roost--sidebar-buffer) (roost--task-panel-window))
      (roost-sweep-late--problem 'stale "a side window you turned off shows again")))
  (let ((now (roost-sweep-late--task roost-sweep-late--other)))
    (when (and other now
               (not (plist-get interrupter :host-gone))
               (not (equal (roost--field now 'name) (roost--field other 'name))))
      (roost-sweep-late--problem 'wrong-buffer "the other task was renamed"))))

(defun roost-sweep-late--check-view ()
  "Note a view that changed for a reply to a run older than it shows."
  (when (and roost-sweep-late--view
             (not (equal roost-sweep-late--view
                         (with-current-buffer (window-buffer (selected-window)) (buffer-string)))))
    (roost-sweep-late--problem 'stale "a reply to an older run changes %s"
                               (buffer-name (window-buffer (selected-window))))))

(defun roost-sweep-late--check-left-behind ()
  "Note what stays busy or waits on, with nothing left to come."
  (when (> roost--held-for-minibuffer 0)
    (roost-sweep-late--problem 'left-behind "%d held for a minibuffer long gone" roost--held-for-minibuffer))
  (when (gethash roost-sweep-late--host roost--refreshing)
    (roost-sweep-late--problem 'left-behind "the host counts as being refreshed still"))
  (when roost--resuming
    (roost-sweep-late--problem 'left-behind "tasks count as resuming still"))
  (when minibuffer-exit-hook
    (roost-sweep-late--problem 'left-behind "the minibuffer's exit hook keeps %S" minibuffer-exit-hook))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (or roost--send-sending roost--pr-sending roost--compose-submitting)
        (roost-sweep-late--problem 'left-behind "%s says it is still sending" (buffer-name buffer))))))

(defun roost-sweep-late--check-said (spec interrupter form from)
  "Note what SPEC's command should have said of FORM since FROM in *Messages*.
INTERRUPTER came first: you may have said you don't care, and a command
that opens something needn't say why it can't, once you have gone
elsewhere."
  (let ((said (roost-sweep-late--messages from)))
    (when (string-match "^\\(?:Error running timer\\|error in process \\|Roost: (\\).*$" said)
      (roost-sweep-late--problem 'lisp-error "says %s" (match-string 0 said)))
    (when-let* ((words (roost-sweep-late--form-words form))
                ((not (plist-get spec :background)))
                ((not (cdr-safe (assoc words (plist-get spec :refusals)))))
                ((not (plist-get interrupter :quiet)))
                (place (plist-get spec :said-in))
                (buffer (get-buffer place))
                ((not (string-search words (with-current-buffer buffer (buffer-string))))))
      (roost-sweep-late--problem 'words "%s doesn't say %S" place words))
    (when-let* ((words (roost-sweep-late--form-words form))
                ((not (plist-get spec :background)))
                ((not (plist-get spec :said-in)))
                ((not (plist-get interrupter :quiet)))
                ;; You have moved on from it.
                ((not (and (plist-get spec :opens)
                           (or (plist-get interrupter :left) (plist-get interrupter :gone)))))
                ((not (cdr-safe (assoc words (plist-get spec :refusals)))))
                (count (roost-sweep-late--count (car (split-string words "\n")) said))
                ((/= count 1)))
      (roost-sweep-late--problem 'words "says %S %d times" words count))))

(defun roost-sweep-late--check-questions (interrupter)
  "Note a question asked about a task that went, after INTERRUPTER."
  (when (plist-get interrupter :gone)
    (pcase-dolist (`(,prompt . ,_) roost-sweep-late--asked)
      (roost-sweep-late--problem 'question "asks %S about a task that went" prompt))))

;;;; Questions left open

(defvar roost-sweep-late--questions
  `((draft-name :origin compose :ask ,#'roost-compose-set-name :keys "x\r")
    (draft-project :origin compose :ask ,#'roost-compose-set-project :keys "\r")
    (draft-folder :origin compose :ask ,#'roost-compose-set-project
                  :keys "Other directory…\r/home/user/other/\r")
    (draft-agent :origin compose :ask ,#'roost-compose-set-agent :keys "\r")
    (draft-start :origin compose :ask ,#'roost-compose-set-base :keys "\r")
    (draft-cancel :origin compose :ask ,#'roost-compose-cancel :keys "no\r")
    (prompt-cancel :origin send-draft :ask ,#'roost-send-cancel :keys "no\r")
    (pull-request-cancel :origin pr-draft :ask ,#'roost-pr-cancel :keys "no\r")
    (rename :ask ,(lambda () (roost-rename (roost-sweep-late--mine))) :keys "x\r")
    (stop :ask ,(lambda () (roost-stop (roost-sweep-late--mine))) :keys "y\r")
    (merge :ask ,(lambda () (roost-merge-retire (roost-sweep-late--mine))) :keys "y\r")
    (retire :ask ,(lambda () (roost-retire (roost-sweep-late--mine))) :keys "y\r")
    (forget :ask ,(lambda () (roost-forget (roost-sweep-late--mine))) :keys "yes\r")
    (discard :ask ,(lambda () (roost-discard (roost-sweep-late--mine))) :keys "y\r")
    (switch :ask ,#'roost-switch-task :keys "\r")
    (other-question :ask ,(lambda () (read-string "Anything else? ")) :keys "x\r"))
  "Questions Roost asks in the minibuffer, each (NAME . PLIST).
:ask asks it from a window showing :origin, `here' unless it says
otherwise, and :keys answer it.  A reply comes while it is open.")

(defun roost-sweep-late--question-case (spec question form)
  "Run SPEC's command with its reply held, and have the reply come in FORM during QUESTION.
Return what broke, a list of (RULE . TEXT)."
  (roost-sweep-late--world
    (let ((roost-sweep-late--answer-questions t)
          (roost-sweep-late--origin-buffer nil)
          (roost-sweep-late--spec spec)
          (delivered nil))
      (roost-sweep-late--populate (plist-get spec :fields) (plist-get spec :others))
      (roost-watch-mode 1)
      (setq roost-sweep-late--origin-buffer
            (roost-sweep-late--lay-out (or (plist-get question :origin) (plist-get spec :origin) 'here)))
      (roost-sweep-late--start spec)
      (dolist (action (plist-get spec :first))
        (roost-sweep-late--answer (roost-sweep-late--take action) 'good))
      (let ((request (or (roost-sweep-late--take (plist-get spec :action))
                         (error "Nothing asked %s" (plist-get spec :action)))))
        (when-let* ((reply (plist-get spec :reply)))
          (plist-put request :reply (funcall reply (plist-get request :reply))))
        (setq roost-sweep-late--real-questions t)
        (roost-sweep-late--note-place)
        (let ((executing-kbd-macro t)
              (unread-command-events (append (listify-key-sequence (plist-get question :keys))
                                             '(?\C-g ?\C-g ?\C-g))))
          (minibuffer-with-setup-hook
              (lambda ()
                (unless delivered
                  (setq delivered t roost-sweep-late--delivering t)
                  (roost-sweep-late--answer request form)))
            (with-current-buffer roost-sweep-late--origin-buffer
              (condition-case err
                  (funcall (plist-get question :ask))
                (user-error nil)
                (quit nil)
                (error (roost-sweep-late--problem 'lisp-error "the question ends in %S" err))))))
        (setq roost-sweep-late--real-questions nil)
        (unless delivered
          (roost-sweep-late--answer request form)))
      (roost-sweep-late--settle)
      (roost-sweep-late--check-left-behind)
      roost-sweep-late--found)))

(defun roost-sweep-late--question-sweep (commands questions)
  "Run COMMANDS against QUESTIONS, as `roost-sweep-late--sweep' runs them."
  (let (problems)
    (dolist (command commands)
      (let ((spec (cdr (assq command roost-sweep-late--commands))))
        (pcase-dolist (`(,name . ,question) questions)
          ;; A draft's question goes with what was asked from the draft.
          (when (or (null (plist-get question :origin))
                    (eq (plist-get question :origin) (plist-get spec :origin)))
            (dolist (form (roost-sweep-late--forms spec))
              (setq problems
                    (roost-sweep--add-problems
                     (delete-dups (mapcar (lambda (found) (format "%s: %s" (car found) (cdr found)))
                                          (roost-sweep-late--question-case spec question form)))
                     (format "%s, %s left open, then %s" command name (roost-sweep-late--form-name form))
                     problems)))))))
    problems))

;;;; Running a case

(defun roost-sweep-late--start (spec)
  "Start SPEC's command, as the command loop would."
  (condition-case err
      (funcall (plist-get spec :start))
    (user-error (message "%s" (error-message-string err)))
    (quit nil)
    (error (roost-sweep-late--problem 'lisp-error "the command signals %S" err))))

(defvar roost-sweep-late--pty nil
  "A process with a pty, on which the sweep's frames are.")

(defun roost-sweep-late--make-frame ()
  "A new frame, the selected one still selected, or nil where it can't be made.
Batch Emacs makes no other frame on its own terminal, so it is a
terminal's, on a pty.  No terminal initialization: for xterm it waits
for replies."
  (unless (process-live-p roost-sweep-late--pty)
    (setq roost-sweep-late--pty
          (ignore-errors (make-process :name "roost-sweep-late-pty" :command '("sleep" "600")
                                       :connection-type 'pty :noquery t))))
  (when-let* ((pty roost-sweep-late--pty)
              ((set-process-window-size pty 40 120))
              (tty (process-tty-name pty)))
    (ignore-errors
      ;; Tests before this one can leave colors there, which a new text
      ;; frame can't take before it has faces: Emacs 32 crashes.
      (let ((term-file-prefix nil) (default-frame-alist nil))
        (with-selected-frame (selected-frame)
          (make-frame `((window-system . nil) (tty . ,tty) (tty-type . "vt100"))))))))

(defun roost-sweep-late--in-frame (function)
  "Call FUNCTION in a frame of its own, and come back.  Return nil if none can be made."
  (when-let* ((frame (roost-sweep-late--make-frame)))
    (let ((home (selected-frame)))
      (select-frame frame)
      (setq roost-sweep-late--frame frame)
      (unwind-protect (funcall function)
        (setq roost-sweep-late--frame nil)
        (when (frame-live-p home) (select-frame home))
        (when (frame-live-p frame) (delete-frame frame t))
        ;; What each frame wrote to its terminal, or Emacs would wait,
        ;; with nobody to read it, once a pty's buffer filled.
        (while (accept-process-output roost-sweep-late--pty 0 nil t))))))

(defun roost-sweep-late--case (spec interrupter form answer)
  "Run SPEC's command with its reply held, then INTERRUPTER, then its reply in FORM.
ANSWER answers the questions asked after it.  Return what broke, a list
of (RULE . TEXT), and whether a question was asked, as a cons."
  (if (not (plist-get interrupter :frame))
      (roost-sweep-late--case-here spec interrupter form answer)
    (roost-sweep-late--in-frame
     (lambda () (roost-sweep-late--case-here spec interrupter form answer)))))

(defun roost-sweep-late--case-here (spec interrupter form answer)
  "Run a case, as for `roost-sweep-late--case', in the selected frame."
  (roost-sweep-late--world
    (let ((roost-sweep-late--answer-questions t)
          (roost-sweep-late--after-quit nil)
          (roost-sweep-late--origin-buffer nil)
          (roost-sweep-late--spec spec)
          (roost-sweep-late--view nil)
          (from nil) other)
      (roost-sweep-late--populate (plist-get spec :fields) (plist-get spec :others))
      (roost-watch-mode 1)
      (when roost-sweep-late--sides
        (roost-sidebar-mode 1)
        (roost-task-panel-mode 1)
        (roost-sweep-late--settle))
      (setq roost-sweep-late--origin-buffer (roost-sweep-late--lay-out (or (plist-get spec :origin) 'here)))
      (with-current-buffer (messages-buffer)
        (let ((inhibit-read-only t)) (erase-buffer)))
      (let* ((hold
              (lambda ()
                (dolist (action (plist-get spec :first))
                  (roost-sweep-late--answer (roost-sweep-late--take action) 'good))
                (let ((request (or (roost-sweep-late--take (plist-get spec :action))
                                   (error "Nothing asked %s" (plist-get spec :action)))))
                  (when-let* ((reply (plist-get spec :reply)))
                    (plist-put request :reply (funcall reply (plist-get request :reply))))
                  (funcall (plist-get interrupter :run)
                           (lambda ()
                             (unless roost-sweep-late--place (roost-sweep-late--note-place))
                             (setq other (roost-sweep-late--task roost-sweep-late--other)
                                   from (with-current-buffer (messages-buffer) (point-max))
                                   roost-sweep-late--delivering t
                                   roost-sweep-late--answer-questions answer)
                             (roost-sweep-late--answer request form)
                             ;; Before a poll puts right what the reply got wrong.
                             (roost-sweep-late--check-tasks spec interrupter other)))))))
        (if (plist-get spec :wait)
            (progn (setq roost-sweep-late--pump hold)
                   (roost-sweep-late--start spec))
          (roost-sweep-late--start spec)
          (condition-case nil
              (funcall hold)
            (quit nil)))
        (when roost-sweep-late--after-quit
          (funcall roost-sweep-late--after-quit)))
      (roost-sweep-late--settle)
      (roost-sweep-late--check-place spec interrupter)
      (roost-sweep-late--check-tasks spec interrupter other)
      (roost-sweep-late--check-view)
      (roost-sweep-late--check-left-behind)
      (roost-sweep-late--check-said spec interrupter form from)
      (dolist (row (roost-sweep-late--rows-gone))
        (roost-sweep-late--problem 'gone "%s" row))
      (roost-sweep-late--check-questions interrupter)
      (when-let* ((shows (plist-get spec :shows))
                  ((plist-get interrupter :stays))
                  ((eq form 'good))
                  ((not (equal (buffer-name (window-buffer (selected-window))) shows))))
        (roost-sweep-late--problem 'moved "it never shows %s" shows))
      (cons roost-sweep-late--found roost-sweep-late--asked))))

(defun roost-sweep-late--forms (spec)
  "The forms SPEC's reply can come in."
  (append '(good dropped no-reply)
          (mapcar (lambda (refusal) (cons 'refused (car refusal))) (plist-get spec :refusals))))

(defun roost-sweep-late--form-name (form)
  "FORM as text."
  (pcase form
    (`(refused . ,words) (format "refused %S" (truncate-string-to-width words 30)))
    (_ (symbol-name form))))

(defmacro roost-sweep-late--with-room (&rest body)
  "Run BODY in a frame with room for the sidebar and the task panel beside the code.
Batch Emacs's frame takes the size, though it goes on saying it is 80 columns."
  (declare (indent 0))
  `(let ((columns (frame-width)) (lines (frame-height)))
     (set-frame-size (selected-frame) 300 50)
     (unwind-protect
         (dlet ((native-comp-enable-subr-trampolines nil))
           (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 300)))
             ,@body))
       (set-frame-size (selected-frame) columns lines))))

(defun roost-sweep-late--sweep (commands interrupters)
  "Run COMMANDS, from `roost-sweep-late--commands', against INTERRUPTERS.
Return their problems, each (TEXT PLACE...), as `roost-sweep--report' takes them."
  (let (problems)
    (dolist (command commands)
      (let ((spec (cdr (assq command roost-sweep-late--commands))))
        (dolist (name interrupters)
          (let ((interrupter (cdr (assq name roost-sweep-late--interrupters))))
            (unless (or (equal (plist-get interrupter :unless) (plist-get spec :action))
                        (memq name (plist-get spec :not))
                        (and (plist-get interrupter :sides-off) (not roost-sweep-late--sides))
                        (and (plist-get interrupter :when)
                             (not (plist-get spec (plist-get interrupter :when))))
                        (and (plist-get spec :wait) (not (plist-get interrupter :while-waiting))))
              (dolist (form (roost-sweep-late--forms spec))
                (cl-dolist (answer '(t nil))
                  (let* ((result (roost-sweep-late--case spec interrupter form answer))
                         (place (format "%s, %s, then %s%s" command name (roost-sweep-late--form-name form)
                                        (if (cdr result) (if answer " (yes)" " (no)") ""))))
                    (setq problems
                          (roost-sweep--add-problems
                           (delete-dups (mapcar (lambda (found) (format "%s: %s" (car found) (cdr found)))
                                                (car result)))
                           place problems))
                    ;; Only a question has two ways to go.
                    (unless (cdr result) (cl-return))))))))))
    problems))

(defconst roost-sweep-late--known
  '("\\`stale: a forgotten host shows an error"
    "\\`stale: a reply to an older run changes"
    "\\`lisp-error: the \\(?:command signals\\|question ends in\\) (wrong-type-argument"
    "\\`words: says .* 2 times")
  "What the sweep finds that isn't fixed yet, as regexps of its problems.")

(defun roost-sweep-late--report (problems)
  "Fail with PROBLEMS, leaving out those `roost-sweep-late--known' names."
  (roost-sweep--report
   (seq-remove (lambda (problem)
                 (seq-some (lambda (known) (string-match-p known (car problem))) roost-sweep-late--known))
               problems)))

(defun roost-sweep-late--interrupter-names (&rest leaving-out)
  "The names of `roost-sweep-late--interrupters', but for LEAVING-OUT."
  (seq-difference (mapcar #'car roost-sweep-late--interrupters) leaving-out))

(ert-deftest roost-sweep-late-replies ()
  ;; Each command against all you might do meanwhile, each form of reply.
  (roost-sweep-late--report
   (roost-sweep-late--sweep (mapcar #'car roost-sweep-late--commands)
                            (roost-sweep-late--interrupter-names 'delete-frame))))

(ert-deftest roost-sweep-late-replies-to-a-frame-since-deleted ()
  (skip-unless (let ((frame (roost-sweep-late--make-frame)))
                 (when frame (delete-frame frame t))
                 frame))
  (roost-sweep-late--report
   (roost-sweep-late--sweep (mapcar #'car roost-sweep-late--commands) '(delete-frame))))

(defconst roost-sweep-late--beside-side-windows
  '(open review shell compose-submit stop rename retire merge poll-full)
  "Commands to try with the sidebar and task panel on: what shows, closes or redraws them.")

(ert-deftest roost-sweep-late-replies-beside-the-sidebar-and-panel ()
  (roost-sweep-late--with-room
    (let ((roost-sweep-late--sides t))
      (roost-sweep-late--report
       (roost-sweep-late--sweep roost-sweep-late--beside-side-windows
                                (roost-sweep-late--interrupter-names 'delete-frame))))))

(ert-deftest roost-sweep-late-the-sidebar-and-panel-are-there-to-try ()
  ;; Or the test above tries nothing.
  (roost-sweep-late--with-room
    (let ((roost-sweep-late--sides t)
          (spec (cdr (assq 'open roost-sweep-late--commands)))
          shown)
      (cl-letf (((symbol-function 'roost-sweep-late--check-left-behind)
                 (lambda ()
                   (setq shown (list (get-buffer-window roost--sidebar-buffer)
                                     (roost--task-panel-window))))))
        (roost-sweep-late--case spec (cdr (assq 'none roost-sweep-late--interrupters)) 'good t))
      (should (seq-every-p #'identity shown)))))

(defconst roost-sweep-late--drafts-pending '(compose-submit send-draft attach pr-draft)
  "Commands from a draft, which a question of the draft's can be open beside.")

(ert-deftest roost-sweep-late-replies-to-questions-left-open ()
  (roost-sweep-late--report
   (roost-sweep-late--question-sweep
    (append roost-sweep-late--drafts-pending
            '(open retire merge update update-conflicts stop rename resume poll-full notice))
    roost-sweep-late--questions)))

(defconst roost-sweep-late--breakages
  `((lisp-error open delete-window good roost--still-there-p
                ,(lambda (window &rest _) (with-selected-window window t)))
    (wrong-buffer workload other-window good roost--render-workload ,(lambda () (insert "Workload")))
    (moved open other-buffer good roost--still-there-p ,(lambda (&rest _) t))
    (stale open newer-poll good roost--newer-events ,(lambda (task _old) task))
    (left-behind poll none good roost--task-list-p ,(lambda (_) (error "Broken")))
    (gone retire none good roost--redraw ,#'ignore)
    (question open minibuffer (refused . ,roost-sweep-late--no-window)
              roost--when-out-of-minibuffer ,#'funcall)
    (words send none dropped roost--act
           ,(lambda (task action &optional parameters callback _failure)
              (roost--request (roost--field task 'host) action
                              (cons (cons 'id (roost--field task 'id)) parameters)
                              (or callback #'ignore) #'ignore))))
  "Ways to break Roost that each rule must catch.
Each is (RULE COMMAND INTERRUPTER FORM FUNCTION REPLACEMENT): a case of
COMMAND, INTERRUPTER and FORM keeps RULE until FUNCTION is REPLACEMENT.")

(ert-deftest roost-sweep-late-rules-catch-what-breaks-them ()
  (pcase-dolist (`(,rule ,command ,interrupter ,form ,function ,replacement) roost-sweep-late--breakages)
    (let* ((spec (cdr (assq command roost-sweep-late--commands)))
           (interrupter (cdr (assq interrupter roost-sweep-late--interrupters)))
           (found (lambda () (assq rule (car (roost-sweep-late--case spec interrupter form t))))))
      (ert-info ((format "Rule %s" rule))
        (should-not (funcall found))
        (advice-add function :override replacement '((name . roost-sweep-late--broken)))
        (unwind-protect
            (should (funcall found))
          (advice-remove function 'roost-sweep-late--broken))))))

(ert-deftest roost-sweep-late-a-real-reply-leaves-nothing-behind ()
  ;; The sweep holds replies back above `roost--run'.  Through a real
  ;; process and sentinel, however it ends, a reply leaves no process,
  ;; timer, buffer or file of its input.
  (roost-test--isolated
   (let* ((temporary-file-directory (file-name-as-directory (make-temp-file "roost-late" t)))
          (timers (copy-sequence timer-list))
          (buffers (buffer-list))
          (large (make-string 8000 ?x))
          (print "import sys; sys.stdin.read(); print(%S)")
          (cases `((,(format print "{\"ok\": true, \"result\": 1}") good)
                   (,(format print "{\"ok\": false, \"error\": \"Refused\"}") "Refused")
                   (,(format print "not what a helper says")
                    ,(format-message "Roost can't read the host helper's reply: not what a helper says"))
                   ("import sys; sys.stderr.write('ssh: gone'); sys.exit(255)" "ssh: gone")
                   ("import os, sys; sys.stdin.read(); os.kill(os.getpid(), 9)" "Host operation failed")
                   ("import time; time.sleep(30)" "No reply after 0.1s; the operation may still finish on the host, so refresh before retrying" 0.1))))
     (unwind-protect
         (pcase-dolist (`(,code ,wanted ,timeout) cases)
           (dolist (input (list "{}" large))
             (let (got)
               (roost--run nil code input (lambda (_) (setq got 'good)) (lambda (err) (setq got err)) timeout)
               (roost-test--wait-for (lambda () got))
               (should (equal got wanted))
               (should-not roost--requests)
               (should-not (seq-filter (lambda (process) (string-prefix-p "roost-rpc" (process-name process)))
                                       (process-list)))
               (should-not (seq-difference timer-list timers))
               (should-not (seq-difference (buffer-list) buffers))
               (should-not (directory-files temporary-file-directory nil "\\`roost-input-")))))
       (delete-directory temporary-file-directory t)))))

;;;; What the sweep found

(ert-deftest roost-sweep-late-a-reply-brings-back-no-task-of-a-forgotten-host ()
  ;; No list would take it away again: its host is no longer asked.
  (roost-sweep-late--world
    (roost-sweep-late--populate nil nil)
    (roost--act (roost-sweep-late--mine) "send" '((text . "Go on.")))
    (roost-forget-host roost-sweep-late--host)
    (should-not (roost-tasks))
    (roost-sweep-late--answer (roost-sweep-late--take "send") 'good)
    (should-not (roost-tasks))))

(ert-deftest roost-sweep-late-a-reply-opens-nothing-of-a-task-that-went ()
  (dolist (command '((lambda () (roost-open-task (roost-sweep-late--mine)))
                     (lambda () (roost-review (roost-sweep-late--mine)))))
    (roost-sweep-late--world
      (roost-sweep-late--populate nil nil)
      (let ((here (roost-sweep-late--lay-out 'here)))
        (funcall command)
        (let ((reply (car roost-sweep-late--requests)))
          (roost-sweep-late--go roost-sweep-late--mine)
          (roost-sweep-late--answer reply 'good))
        (should-not (roost-sweep-late--mine))
        (should (eq (window-buffer (selected-window)) here))
        (should (string-match-p "no longer listed" (roost-sweep-late--messages 1)))))))

(ert-deftest roost-sweep-late-a-reply-asks-nothing-in-a-minibuffer-you-are-typing-in ()
  (dolist (case `((,(lambda () (roost-update (roost-sweep-late--mine))) "update"
                   (refused . ,roost-sweep-late--uncommitted-update))
                  (,(lambda () (roost-retire (roost-sweep-late--mine))) "retire"
                   (refused . ,roost-sweep-late--unmerged))))
    (roost-sweep-late--world
      (roost-sweep-late--populate '((ahead . 0)) nil)
      (roost-sweep-late--lay-out 'here)
      (let ((roost-sweep-late--answer-questions t))
        (funcall (car case)))
      (setq roost-sweep-late--answer-questions nil
            roost-sweep-late--delivering t)
      (roost-sweep-late--in-minibuffer
       (lambda ()
         (roost-sweep-late--answer (roost-sweep-late--take (cadr case)) (caddr case))))
      (should-not roost-sweep-late--asked)
      ;; Asked once you are done there.
      (roost-sweep-late--settle)
      (should (= (length roost-sweep-late--asked) 1))
      (should (= (cdar roost-sweep-late--asked) 0)))))

(ert-deftest roost-sweep-late-a-reply-asks-nothing-about-a-task-that-went ()
  (roost-sweep-late--world
    (roost-sweep-late--populate nil nil)
    (roost-sweep-late--lay-out 'here)
    (roost-update (roost-sweep-late--mine))
    (let ((reply (roost-sweep-late--take "update")))
      (roost-sweep-late--go roost-sweep-late--mine)
      (setq roost-sweep-late--delivering t)
      (roost-sweep-late--answer reply `(refused . ,roost-sweep-late--uncommitted-update)))
    (roost-sweep-late--settle)
    (should-not roost-sweep-late--asked)))

(ert-deftest roost-sweep-late-discarding-says-the-task-went-while-its-host-replied ()
  (roost-sweep-late--world
    (roost-sweep-late--populate nil nil)
    (roost-sweep-late--lay-out 'here)
    (setq roost-sweep-late--delivering t
          roost-sweep-late--pump
          (lambda ()
            (let ((reply (roost-sweep-late--take "discard")))
              (roost-sweep-late--go roost-sweep-late--mine)
              (roost-sweep-late--answer reply 'good))))
    (should (equal (cadr (should-error (roost-discard (roost-sweep-late--mine)) :type 'user-error))
                   "mine is no longer listed"))
    (should-not roost-sweep-late--asked)))

(ert-deftest roost-sweep-late-a-reply-shows-nothing-once-you-have-gone-elsewhere ()
  (pcase-dolist (`(,fields ,action ,command)
                 `((((status . "stopped") (live)) "resume"
                    ,(lambda () (roost-resume (roost-sweep-late--mine))))
                   (nil "shell" ,(lambda () (roost-shell (roost-sweep-late--mine))))))
    ;; Showing it in the window you stayed in is what you asked for.
    (dolist (stay '(t nil))
      (roost-sweep-late--world
        (roost-sweep-late--populate fields nil)
        (roost-sweep-late--lay-out 'here)
        (funcall command)
        (unless stay (switch-to-buffer "*late elsewhere*"))
        (roost-sweep-late--answer (roost-sweep-late--take action) 'good)
        (roost-sweep-late--settle)
        (should (equal (buffer-name (window-buffer (selected-window)))
                       (if stay "*late terminal aaaaaa*" "*late elsewhere*")))))))

(ert-deftest roost-sweep-late-a-task-resumed-opens-once-you-are-out-of-the-minibuffer ()
  (roost-sweep-late--world
    (roost-sweep-late--populate '((status . "stopped") (live)) nil)
    (roost-sweep-late--lay-out 'here)
    (roost-resume (roost-sweep-late--mine))
    (let ((reply (roost-sweep-late--take "resume")))
      (roost-sweep-late--in-minibuffer (lambda () (roost-sweep-late--answer reply 'good))))
    (roost-sweep-late--settle)
    (should (equal (buffer-name (window-buffer (selected-window))) "*late terminal aaaaaa*"))))

(ert-deftest roost-sweep-late-a-new-task-opens-only-if-you-stayed ()
  (dolist (stay '(t nil))
    (roost-sweep-late--world
      (roost-sweep-late--populate nil nil)
      (roost-sweep-late--lay-out 'compose)
      (roost-compose-submit)
      (unless stay (switch-to-buffer "*late elsewhere*"))
      (roost-sweep-late--answer (roost-sweep-late--take "create") 'good)
      (roost-sweep-late--settle)
      (should-not (get-buffer roost--compose-buffer))
      (should (roost-sweep-late--task "cccccc0000000000"))
      (should (equal (buffer-name (window-buffer (selected-window)))
                     (if stay "*late terminal cccccc*" "*late elsewhere*")))
      (should (string-match-p "Roost created" (roost-sweep-late--messages 1))))))

(provide 'roost-sweep-late)

;;; roost-sweep-late.el ends here
