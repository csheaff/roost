;;; roost-sweep.el --- Rules every Roost view keeps, in every task state  -*- lexical-binding: t -*-

;;; Commentary:

;; The tests in roost-test.el each check what someone thought to check.
;; These draw Roost's views for each of a gallery of task states, press
;; every button and key there, and check rules that hold for all of them:
;;
;; - A view draws without an error, and drawing it again changes nothing.
;; - What a view draws doesn't depend on the windows showing it: none,
;;   the one you are in, one beside it (as a panel beside the terminal
;;   you type in), or two.
;; - A button or key does its job, says why it can't (`user-error'), or
;;   asks; it never ends in a Lisp error.
;; - A button or key that changes only the view keeps that change through
;;   a redraw, and another button or key changes it back.
;; - A key the view tells you to press is bound there, and its command
;;   applies to the task.
;;
;; A new button or key is covered without a test of its own; a new kind
;; of task gets a state in `roost-sweep--gallery'.  The world outside the
;; view is stubbed: requests to hosts, processes, the browser, Magit,
;; tmux-control and the menu are recorded and stop the command there, and
;; a question is answered with C-g.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'roost)
(require 'roost-test)

(defconst roost-sweep--long-prompt
  (concat "Make the report show how much is left of each budget, and flag the "
          "categories that are over. "
          (mapconcat (lambda (n) (format "Detail %d of what the report should do." n))
                     (number-sequence 1 30) " ")
          "\n\nAdd a test, then run the tests with python3 -m unittest.")
  "A prompt the task panel folds.")

(defconst roost-sweep--long-reply
  (concat "I made the change; see [the report](https://example.com/report) and "
          "https://example.com/ci for the run.\n\n"
          (mapconcat (lambda (n) (format "Progress item %d: handled the edge case." n))
                     (number-sequence 1 30) "\n\n"))
  "A reply the task panel folds when narrow, with links in it.")

(defun roost-sweep--files (&rest specs)
  "Changed files from SPECS, each (PATH . KIND).
KIND is `committed', `uncommitted', `untracked' or `binary'."
  (mapcar (lambda (spec)
            (pcase (cdr spec)
              ('committed `((path . ,(car spec)) (added . 12) (deleted . 3)))
              ('uncommitted `((path . ,(car spec)) (added . 4) (deleted . 1) (uncommitted . t)))
              ('untracked `((path . ,(car spec)) (untracked . t)))
              ('binary `((path . ,(car spec)) (uncommitted . t)))))
          specs))

(defconst roost-sweep--recent "2999-01-01T00:00:00+00:00"
  "An update time no task has outgrown.")

(defvar roost-sweep--gallery
  `(("starting" (status . "starting") (updatedAt . ,roost-sweep--recent) (live . t))
    ("stuck starting" (status . "starting") (live . t))
    ("codex starting" (status . "starting") (agent . "codex") (live . t))
    ("running" (status . "running") (live . t) (task . ,roost-sweep--long-prompt)
     (diff . "") (ahead . 0))
    ("permission" (status . "permission") (live . t) (request . "Asks to run python3 -m unittest")
     (task . ,roost-sweep--long-prompt) (lastMessage . ,roost-sweep--long-reply)
     (diff . "2 files +16 −4 · uncommitted") (dirty . t) (ahead . 0)
     (files . ,(roost-sweep--files '("ledger.py" . uncommitted) '("test_ledger.py" . uncommitted))))
    ("ready, reviewing" (status . "ready") (live . t) (lastMessage . ,roost-sweep--long-reply)
     (task . ,roost-sweep--long-prompt) (diff . "3 files +28 −7 · uncommitted") (dirty . t) (ahead . 1)
     (files . ,(roost-sweep--files '("ledger.py" . uncommitted) '("notes.md" . untracked)
                                   '("report.py" . committed))))
    ("ready, committed" (status . "ready") (live . t) (lastMessage . "Done. Tests pass.")
     (diff . "1 file +12 −3") (ahead . 2) (files . ,(roost-sweep--files '("report.py" . committed))))
    ("seen" (status . "ready") (live . t) (lastMessage . "Done.") (seen . "2026-10-03T20:00:00+00:00")
     (diff . "") (ahead . 0))
    ("interrupted" (status . "ready") (lastEvent . "Interrupt") (live . t) (diff . "") (ahead . 0))
    ("failed turn" (status . "failed") (live . t) (error . "You've hit your usage limit")
     (diff . "") (ahead . 0))
    ("stopped" (status . "stopped") (live) (diff . "") (ahead . 1)
     (files . ,(roost-sweep--files '("report.py" . committed))))
    ("crashed" (status . "crashed") (live) (error . "The agent exited with status 1"))
    ("worktree gone" (status . "ready") (live) (worktreeMissing . t))
    ("merge conflicts" (status . "ready") (live . t) (integrationBranch . "main")
     (merging (conflicts "ledger.py" "report.py")) (diff . "1 file +1 −1 · uncommitted")
     (files . ,(roost-sweep--files '("ledger.py" . uncommitted))))
    ("behind" (status . "ready") (live . t) (integrationBranch . "main") (behind . 3) (ahead . 1)
     (diff . "1 file +12 −3") (files . ,(roost-sweep--files '("report.py" . committed))))
    ("pull request open" (status . "ready") (live . t) (ahead . 2) (diff . "1 file +12 −3")
     (pr (number . 12) (url . "https://github.com/o/r/pull/12"))
     (prStatus (state . "OPEN") (review . "REVIEW_REQUIRED")
               (checks (passing . 3) (failing . 1) (pending . 1))))
    ("pull request merged" (status . "ready") (live . t) (ahead . 2)
     (pr (number . 12) (url . "https://github.com/o/r/pull/12")) (prStatus (state . "MERGED")))
    ("from an issue" (status . "running") (live . t)
     (issue (number . 70) (url . "https://github.com/o/r/issues/70") (title . "Off-by-one scroll")))
    ("agent's own worktrees" (status . "ready") (live . t) (ahead . 0)
     (agentWork ((path . "/repo/.claude/worktrees/probe") (branch . "probe") (ahead . 1))
                ((path . "/repo/.claude/worktrees/spare") (ahead . 0))))
    ("many files" (status . "ready") (live . t) (dirty . t) (ahead . 1) (diff . "16 files +80 −20")
     (files . ,(apply #'roost-sweep--files
                      (append '(("logo.png" . binary) ("new.py" . untracked))
                              (mapcar (lambda (n) (cons (format "src/a/rather/long/path/module%d.py" n)
                                                        (if (cl-oddp n) 'uncommitted 'committed)))
                                      (number-sequence 1 14))))))
    ("with notes" (status . "ready") (live . t) (dirty . t) (diff . "1 file +4 −1 · uncommitted")
     (files . ,(roost-sweep--files '("ledger.py" . uncommitted))))
    ("unreachable host" (host . "gone") (status . "running") (live . t)))
  "Task states the views are drawn for: (NAME . FIELDS).
FIELDS go over those of `roost-test--task', on host \"dev\" unless they
name another.  Each state is a task of its own, with an ID from its
place here, so the dashboard and sidebar show them all at once.")

(defun roost-sweep--key (name)
  "The key of the task for gallery state NAME."
  (let ((host (or (alist-get 'host (cdr (assoc name roost-sweep--gallery))) "dev"))
        (index (cl-position name roost-sweep--gallery :key #'car :test #'equal)))
    (list host (format "%016d" index))))

(defun roost-sweep--populate ()
  "Cache a task for each state of the gallery, and what goes with them."
  (cl-loop for (name . fields) in roost-sweep--gallery
           for key = (roost-sweep--key name)
           do (roost--cache-task (car key)
                                 (append (assq-delete-all 'host (copy-tree fields))
                                         `((id . ,(cadr key)) (name . ,name) (repo . "/home/user/ledger")
                                           (branch . ,(format "roost/%s" (replace-regexp-in-string " " "-" name))))
                                         (roost-test--task (cadr key)))))
  (puthash "gone" "ssh: connect to host gone: Connection refused" roost--errors)
  (setq roost--notes
        (list (roost-test--note "n1" (cadr (roost-sweep--key "with notes"))
                                '(file . "ledger.py") '(line . 3) '(end . 3) '(text . "Keep the sign.")))))

;;;; The world outside the view

(define-error 'roost-sweep-outside "Reached outside the view")

(defvar roost-sweep--effects nil
  "What the action under way did outside the view, newest first.")

(eval-and-compile
  (defconst roost-sweep--outside
    '(;; Hosts and processes
      roost--request roost--request-wait process-file make-process start-process
      start-file-process call-process roost--notify
      ;; A task's terminal, the menu, other packages and the browser
      roost--display-task transient-setup magit-status magit-diff-working-tree magit-diff-dwim
      find-file find-file-other-window dired browse-url)
    "Functions that reach outside the view.
Called, they are recorded and stop the command.")

  (defconst roost-sweep--questions
    '(y-or-n-p yes-or-no-p read-string read-from-minibuffer completing-read read-char-choice
      read-key read-char read-char-exclusive read-event read-number read-file-name
      read-directory-name read-multiple-choice read-answer read-shell-command map-y-or-n-p)
    "Functions that ask: called, they are recorded and answered with C-g."))

(defvar native-comp-enable-subr-trampolines)

(defmacro roost-sweep--world (&rest body)
  "Run BODY with the outside world stubbed and fresh Roost state."
  (declare (indent 0))
  `(roost-test--isolated
    (roost-sweep--populate)
    (let ((roost-sweep--effects nil)
          (inhibit-message t)
          (message-log-max nil)
          ;; Natively compiled, a stubbed primitive needs a trampoline,
          ;; and compiling one runs a process; Roost runs from source here.
          (native-comp-enable-subr-trampolines nil))
      (cl-letf* (,@(mapcar (lambda (f)
                             `((symbol-function ',f)
                               (lambda (&rest args)
                                 (push (cons ',f args) roost-sweep--effects)
                                 (signal 'roost-sweep-outside (list ',f)))))
                           roost-sweep--outside)
                 ,@(mapcar (lambda (f)
                             `((symbol-function ',f)
                               (lambda (&rest args)
                                 (push (cons ',f args) roost-sweep--effects)
                                 (signal 'quit nil))))
                           roost-sweep--questions)
                 ;; Global modes have tests of their own; here they are only noted.
                 ((symbol-function 'roost-watch-mode)
                  (lambda (&rest args) (push (cons 'roost-watch-mode args) roost-sweep--effects))))
        ,@body))))

;;;; Views

(defmacro roost-sweep--at-width (width &rest body)
  "Run BODY with task panels WIDTH columns wide.
With WIDTH nil, as wide as their windows."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'roost--task-info-width)
              (let ((measure (symbol-function 'roost--task-info-width)))
                (lambda () (or ,width (funcall measure))))))
     ,@body))

(defun roost-sweep--panel-setup (state)
  "Make the current buffer the task panel of STATE's task."
  (setq roost--buffer-task-key (roost-sweep--key state)))

(defun roost-sweep--row (state)
  "Where STATE's task is in the current list of tasks, or nil."
  (roost--task-row (roost-sweep--key state)))

(defun roost-sweep--search-replies ()
  "Search results for the gallery's tasks on \"dev\" and a past task.
Host \"gone\" failed to search."
  `(("dev"
     (tasks
      ,@(cl-loop for (name . fields) in roost-sweep--gallery
                 unless (alist-get 'host fields)
                 collect `((id . ,(cadr (roost-sweep--key name))) (name . ,name) (repo . "/home/user/ledger")
                           (hits ((at . "2026-10-01T10:01:00Z") (role . "user") (session . "s1") (line . 3)
                                  (snippet . "Make the report show what is left")
                                  (text . ,roost-sweep--long-prompt))
                                 ((at . "2026-10-01T10:02:00Z") (role . "assistant") (session . "s1") (line . 4)
                                  (snippet . "I made the report change")
                                  (text . ,roost-sweep--long-reply)))
                           (more . 2)))
      ((past . t) (key . "0a1b2c3d4e/old-report-9f8e7d") (name . "old report") (repo)
       (hits ((at . "2026-09-01T10:00:00Z") (role . "user") (session . "s2") (line . 7)
              (snippet . "An older report") (text . "An older report\nin two lines")))
       (more . 0)))
     (moreTasks . 1))
    ("gone" :error "ssh: connect to host gone: Connection refused")))

(defun roost-sweep--search-setup (_state)
  "Make the current buffer show search results for the gallery."
  (setq roost--search-query "report"
        roost--search-hosts '("dev" "gone")
        roost--search-replies (roost-sweep--search-replies)))

(defun roost-sweep--hit (state)
  "Where the first message of STATE's task is in the search results, or nil."
  (let ((key (roost-sweep--key state)) (pos (point-min)) found)
    (while (and (not found) (setq pos (next-single-property-change pos 'roost-search-line)))
      (when (and (get-text-property pos 'roost-search-line)
                 (equal (get-text-property pos 'roost-task) key))
        (setq found pos)))
    found))

(defvar roost-sweep--views
  '((panel :mode roost-task-info-mode :render roost--render-task-info :widths (40 100)
           :layouts (selected none other both) :setup roost-sweep--panel-setup)
    (dashboard :mode roost-dashboard-mode :render roost--render-dashboard :buffer "*roost*"
               :layouts (selected none other both) :point roost-sweep--row :sized t)
    (sidebar :mode roost-sidebar-list-mode :render roost--render-sidebar
             :layouts (selected none other both) :point roost-sweep--row :sized t)
    (search :mode roost-search-mode :render roost--render-search :buffer "*roost search*"
            :layouts (selected none other both) :setup roost-sweep--search-setup :point roost-sweep--hit
            :sized t))
  "Roost's views, each (NAME . PLIST).
:mode makes the buffer, :setup gives it what it shows for a state,
:render draws it, :point finds the state's task in it, and :buffer names
it.  :widths are the task panel's widths to try, and :layouts the
windows to show it in, the first as actions are tried: see
`roost-sweep--draw'.  :sized means it fits the window it is in, so with
none it draws for a width of its own, and isn't compared with the rest.")

(defun roost-sweep--view (view property)
  "PROPERTY of VIEW in `roost-sweep--views'."
  (plist-get (cdr (assq view roost-sweep--views)) property))

(defun roost-sweep--draw (view state width &optional layout)
  "Make and draw VIEW for gallery STATE at WIDTH, in windows as LAYOUT says.
LAYOUT is `selected', the window you are in, unless given; `none', no
window; `other', a window beside the one you are in, as a panel is
beside the terminal you type in; or `both'.  Return the buffer, current,
with point on STATE's task in a list."
  (let ((buffer (generate-new-buffer (or (roost-sweep--view view :buffer) (format "*sweep %s*" view)))))
    (delete-other-windows)
    (set-window-buffer (selected-window) (get-buffer-create "*sweep elsewhere*"))
    (pcase (or layout 'selected)
      ('selected (set-window-buffer (selected-window) buffer))
      ('other (set-window-buffer (split-window) buffer))
      ('both (set-window-buffer (selected-window) buffer)
             (set-window-buffer (split-window) buffer)))
    (set-buffer buffer)
    (funcall (roost-sweep--view view :mode))
    (when-let* ((setup (roost-sweep--view view :setup))) (funcall setup state))
    (roost-sweep--at-width width
      (funcall (roost-sweep--view view :render)))
    (when-let* ((find (roost-sweep--view view :point))
                (place (funcall find state)))
      (goto-char place)
      (dolist (window (get-buffer-window-list buffer))
        (set-window-point window place)))
    buffer))

(defun roost-sweep--layout (layout)
  "LAYOUT, from `roost-sweep--draw', as text."
  (pcase layout
    ('none "in no window")
    ('selected "in the window you are in")
    ('other "beside the window you are in")
    ('both "in two windows")))

(defun roost-sweep--text ()
  "The current buffer's text, without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun roost-sweep--button-starts ()
  "The buttons in the current buffer, each (LABEL OCCURRENCE . START).
OCCURRENCE counts the buttons before it with the same label."
  (let (found (pos (point-min)))
    (while (< (setq pos (next-single-char-property-change pos 'button)) (point-max))
      (when (get-char-property pos 'button)
        (let* ((end (next-single-char-property-change pos 'button))
               (label (buffer-substring-no-properties pos end)))
          (push (cons label (cons (cl-count label found :key #'car :test #'equal) pos)) found)
          (setq pos end))))
    (nreverse found)))

(defun roost-sweep--buttons ()
  "The buttons in the current buffer, each (LABEL . OCCURRENCE)."
  (mapcar (lambda (button) (cons (car button) (cadr button))) (roost-sweep--button-starts)))

(defun roost-sweep--keys ()
  "The keys the current buffer's mode binds, each (KEY . COMMAND).
Those of the modes Roost's derive from, such as `special-mode', are left
out, and so are mouse events, prefix keys, and keys whose commands
switch global modes, which roost-test.el covers."
  (let (found)
    (cl-labels ((walk (map)
                  (map-keymap-internal
                   (lambda (event binding)
                     (when (and (symbolp binding) (commandp binding)
                                (not (memq binding '(roost-task-panel-mode roost-sidebar-mode)))
                                (not (consp event))
                                (not (and (symbolp event)
                                          (string-match-p "mouse\\|menu-bar\\|remap"
                                                          (symbol-name event))))
                                (not (assoc (vector event) found)))
                       (push (cons (vector event) binding) found)))
                   map)
                  (when-let* ((parent (keymap-parent map))
                              ((not (eq parent special-mode-map))))
                    (walk parent))))
      (walk (current-local-map)))
    (nreverse found)))

(defun roost-sweep--do (action)
  "Do ACTION in the current buffer: (button LABEL . N) or (key KEY . COMMAND).
Return nil, or the error it ended in when that is a Lisp error."
  (condition-case err
      (progn
        (pcase action
          (`(button ,label . ,n)
           ;; Found by its property: the same words can be plain text too.
           (goto-char (or (cddr (seq-find (lambda (button) (equal (cons (car button) (cadr button))
                                                                   (cons label n)))
                                          (roost-sweep--button-starts)))
                          (error "No button %S here" label)))
           (push-button (point)))
          (`(key ,key . ,command)
           (let ((last-command-event (aref key (1- (length key))))
                 (this-command command)
                 (current-prefix-arg nil))
             (call-interactively command nil key))))
        nil)
    ((user-error quit roost-sweep-outside beginning-of-buffer end-of-buffer) nil)
    (error err)))

(defun roost-sweep--try (view state width actions)
  "Draw VIEW for STATE at WIDTH and do ACTIONS.
Return a plist: :text, the view's text after them; :error, from the
first action that ended in a Lisp error; :outside, when an action
reached outside the view, opened a buffer or showed another; :redrawn,
the text after drawing the view again; and :actions, the buttons and
keys there are then."
  (roost-sweep--world
    (save-window-excursion
      (let* ((existing (buffer-list))
             (buffer (roost-sweep--draw view state width))
             ;; Buffers the drawing made are the view's.
             (before (buffer-list))
             (window (selected-window))
             error)
        (unwind-protect
            (roost-sweep--at-width width
              (dolist (action actions)
                (when (buffer-live-p buffer)
                  (set-buffer buffer)
                  (unless error (setq error (roost-sweep--do action)))))
              (let ((outside (or roost-sweep--effects
                                 (not (buffer-live-p buffer))
                                 (not (eq (window-buffer window) buffer))
                                 ;; Those named with a space are Roost's scratch.
                                 (seq-remove (lambda (new) (string-prefix-p " " (buffer-name new)))
                                             (cl-set-difference (buffer-list) before)))))
                (if (not (buffer-live-p buffer))
                    (list :error error :outside outside)
                  (set-buffer buffer)
                  (let ((text (roost-sweep--text)))
                    (funcall (roost-sweep--view view :render))
                    (list :text text :error error :outside outside
                          :redrawn (roost-sweep--text)
                          :actions (append (mapcar (lambda (b) (cons 'button b)) (roost-sweep--buttons))
                                           (mapcar (lambda (k) (cons 'key k)) (roost-sweep--keys))))))))
          (dolist (new (buffer-list))
            (unless (memq new existing) (kill-buffer new))))))))

(defun roost-sweep--describe (action)
  "ACTION, from `roost-sweep--do', as text."
  (pcase action
    (`(button ,label . ,_) (format "button %S" label))
    (`(key ,key . ,command) (format "%s (%s)" (key-description key) command))))

;;;; Rules

(defun roost-sweep--check-drawing (view state width)
  "Problems drawing VIEW for STATE at WIDTH: errors, redraws, windows."
  (let (problems texts)
    (dolist (layout (roost-sweep--view view :layouts))
      (condition-case err
          (roost-sweep--world
            (save-window-excursion
              (let ((buffer (roost-sweep--draw view state width layout)))
                (unwind-protect
                    (let ((text (roost-sweep--text)) (point (point)))
                      (roost-sweep--at-width width
                        (funcall (roost-sweep--view view :render)))
                      (unless (equal text (roost-sweep--text))
                        (push (format "drawing it again changes it, shown %s" (roost-sweep--layout layout))
                              problems))
                      (unless (= point (point))
                        (push (format "drawing it again moves point from %d to %d" point (point)) problems))
                      (push (cons layout text) texts))
                  (kill-buffer buffer)))))
        (error (push (format "drawing it fails, shown %s: %S" (roost-sweep--layout layout) err) problems))))
    ;; Drawn in no window, a view that fits its window has another width.
    (when (roost-sweep--view view :sized)
      (setq texts (assq-delete-all 'none texts)))
    (let ((first (cdar (last texts))))
      (dolist (entry texts)
        (unless (equal (cdr entry) first)
          (push (format "it draws differently shown %s than %s"
                        (roost-sweep--layout (car entry)) (roost-sweep--layout (caar (last texts))))
                problems))))
    problems))

(defun roost-sweep--check-actions (view state width)
  "Problems with the buttons and keys of VIEW for STATE at WIDTH."
  (let* ((start (roost-sweep--try view state width nil))
         (original (plist-get start :text))
         problems)
    (dolist (action (plist-get start :actions))
      (let* ((result (roost-sweep--try view state width (list action)))
             (name (roost-sweep--describe action)))
        (cond
         ((plist-get result :error)
          (push (format "%s fails: %S" name (plist-get result :error)) problems))
         ((or (plist-get result :outside) (equal (plist-get result :text) original)))
         ((not (equal (plist-get result :text) (plist-get result :redrawn)))
          (push (format "%s changes the view, and a redraw undoes it" name) problems))
         ((not (seq-some (lambda (back)
                           (let ((undone (roost-sweep--try view state width (list action back))))
                             (and (not (plist-get undone :outside))
                                  (not (plist-get undone :error))
                                  (equal (plist-get undone :text) original))))
                         (plist-get result :actions)))
          (push (format "%s changes the view, and nothing changes it back" name) problems)))))
    problems))

(defun roost-sweep--check-named-keys (view state width)
  "Problems with the keys VIEW for STATE at WIDTH tells you to press.
Each key in what to do next must be bound there to a command that
applies to the task."
  (roost-sweep--world
    (save-window-excursion
      (let ((buffer (roost-sweep--draw view state width)) problems)
        (unwind-protect
            (let ((task (gethash (roost-sweep--key state) roost--tasks))
                  (pos (point-min)))
              (while (setq pos (roost-sweep--face-span pos 'roost-key))
                (let* ((key (buffer-substring-no-properties (car pos) (cdr pos)))
                       (command (ignore-errors (keymap-lookup (current-local-map) key))))
                  (cond ((not (commandp command))
                         (push (format "it names %s, which is not bound there" key) problems))
                        ((and task (not (get-char-property (car pos) 'button))
                              (not (roost--action-applies-p task command)))
                         (push (format "it names %s, but %s doesn't apply to the task" key command)
                               problems)))
                  (setq pos (cdr pos)))))
          (kill-buffer buffer))
        problems))))

(defun roost-sweep--face-span (pos face)
  "The next span from POS with FACE among its faces, as (START . END), or nil."
  (let ((start (roost-sweep--face-start pos face)))
    (when start
      (cons start (or (next-single-property-change start 'face) (point-max))))))

(defun roost-sweep--face-start (pos face)
  "The first position from POS whose faces include FACE, or nil."
  (catch 'found
    (while (< pos (point-max))
      (let ((faces (ensure-list (get-text-property pos 'face))))
        (when (memq face faces) (throw 'found pos)))
      (setq pos (next-single-property-change pos 'face nil (point-max))))
    nil))

(defun roost-sweep--run (rule views)
  "Problems RULE finds in each of VIEWS, for each state and width.
Return them as (PROBLEM . PLACES), PLACES naming the view, state and width."
  (let (problems)
    (dolist (view views)
      (dolist (state (mapcar #'car roost-sweep--gallery))
        (dolist (width (or (roost-sweep--view view :widths) '(nil)))
          (dolist (problem (funcall rule view state width))
            (let ((place (format "%s, %s%s" view state (if width (format " at %d" width) "")))
                  (entry (assoc problem problems)))
              (if entry
                  (unless (member place (cdr entry)) (setcdr entry (append (cdr entry) (list place))))
                (push (list problem place) problems)))))))
    (nreverse problems)))

(defun roost-sweep--report (problems)
  "Fail with PROBLEMS, from `roost-sweep--run', if there are any."
  (when problems
    (ert-fail
     (mapconcat (lambda (entry)
                  (let ((places (cdr entry)))
                    (format "%s\n  in %s%s" (car entry)
                            (string-join (seq-take places 4) "; ")
                            (if (length> places 4) (format "; and %d more" (- (length places) 4)) ""))))
                problems "\n"))))

(ert-deftest roost-sweep-reaches-what-it-checks ()
  ;; A sweep that stopped finding buttons, or took every press for one
  ;; that reached outside, would pass without checking anything.
  (roost-test--isolated
   (let (buttons keys)
     (dolist (view (mapcar #'car roost-sweep--views))
       (dolist (state (mapcar #'car roost-sweep--gallery))
         (let ((start (roost-sweep--try view state (car (roost-sweep--view view :widths)) nil)))
           (dolist (action (plist-get start :actions))
             (pcase action
               (`(button ,label . ,_) (cl-pushnew label buttons :test #'equal))
               (`(key ,_ . ,command) (cl-pushnew (cons view command) keys :test #'equal)))))))
     (dolist (label '("Show the whole prompt" "Show the whole reply" "ledger.py" "notes.md" "#12" "#70"
                      "probe" "the report" "https://example.com/ci" "+"))
       (should (member label buttons)))
     (dolist (view (mapcar #'car roost-sweep--views))
       (should (length> (seq-filter (lambda (key) (eq (car key) view)) keys) 6))))
   (pcase-dolist (`(,view ,state ,width ,action)
                  '((panel "running" 40 (button "Show the whole prompt" . 0))
                    (panel "permission" 40 (button "Show the whole reply" . 0))
                    (search "running" nil (key [?\t] . roost-search-toggle))))
     (let ((start (roost-sweep--try view state width nil))
           (changed (roost-sweep--try view state width (list action))))
       (should-not (plist-get changed :outside))
       (should-not (plist-get changed :error))
       (should-not (equal (plist-get changed :text) (plist-get start :text)))))
   ;; A button is pressed, not the same words in plain text before it:
   ;; the prompt says "the report" too.
   (let ((link (roost-sweep--try 'panel "permission" 40 '((button "the report" . 0)))))
     (should (equal (cdr (assq 'browse-url (plist-get link :outside))) '("https://example.com/report"))))))

(ert-deftest roost-sweep-views-draw-the-same-each-time ()
  (roost-test--isolated
   (roost-sweep--report (roost-sweep--run #'roost-sweep--check-drawing (mapcar #'car roost-sweep--views)))))

(ert-deftest roost-sweep-buttons-and-keys-work-and-their-changes-go-back ()
  (roost-test--isolated
   (roost-sweep--report (roost-sweep--run #'roost-sweep--check-actions (mapcar #'car roost-sweep--views)))))

(ert-deftest roost-sweep-named-keys-apply ()
  ;; Only the task panel says what to do next.
  (roost-test--isolated
   (roost-sweep--report (roost-sweep--run #'roost-sweep--check-named-keys '(panel)))))

(provide 'roost-sweep)

;;; roost-sweep.el ends here
