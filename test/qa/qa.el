;;; qa.el --- What test/qa/qa.py asks of the Emacs it drives  -*- lexical-binding: t -*-

;;; Commentary:

;; qa.py starts a GUI Emacs of its own and drives it through emacsclient
;; with these functions.  Input goes in as events, as from the keyboard
;; and mouse, so it runs through the command loop, keymaps and redisplay;
;; what is on screen comes back as JSON.  Errors are collected wherever
;; they happen: in commands, timers, process filters and hooks.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'button)
(require 'ert)
(require 'roost)

(declare-function tmux-control-pause-log-mode "tmux-control" (&optional arg))
(declare-function tmux-control--pause-log-took "tmux-control" (start what))
(defvar tmux-control--pause-log)
(defvar tmux-control-pause-log-threshold)
(defvar tmux-control--process)
(defvar tmux-control--controller)
(declare-function tmux-control-buffer-host "tmux-control" ())
(declare-function tmux-control-buffer-socket-name "tmux-control" ())
(declare-function tmux-control-buffer-session "tmux-control" ())

(defvar qa--errors nil
  "Errors since `qa-take-errors' last ran, newest first, as strings.")

(defvar qa--messages-seen 0
  "How far *Messages* has been read for errors.")

(defun qa--command-error (data context caller)
  "Record DATA, unless the user quit or a command said why it couldn't.
Then report it as Emacs would, with CONTEXT and CALLER."
  (unless (memq (car data) '(quit minibuffer-quit user-error))
    (push (format "%s%s: %S" (or context "") (or caller this-command) data) qa--errors))
  (command-error-default-function data context caller))

(setq command-error-function #'qa--command-error)

(defun qa--messages-errors ()
  "Errors Emacs wrote to *Messages* since the last look: from timers,
process filters and sentinels, and hooks, which never reach a command."
  (with-current-buffer (messages-buffer)
    (let ((found nil))
      (save-excursion
        (goto-char (min qa--messages-seen (point-max)))
        (while (re-search-forward
                (concat "^\\(?:Error running timer\\|error in process \\(?:filter\\|sentinel\\)"
                        "\\|Error in [^ ]+-\\(?:hook\\|functions\\)\\|Error during redisplay\\).*")
                nil t)
          (push (match-string 0) found))
        (setq qa--messages-seen (point-max)))
      found)))

(defvar qa--pauses-seen nil
  "The latest of tmux-control's pause notes `qa-take-pauses' has returned.")

(defmacro qa--own-work (&rest body)
  "Run BODY, a long request from qa.py, such as the sweep, as work of its own.
The pause log then blames it for the pause it makes, which
`qa-take-pauses' leaves out.  The server's own functions can't be
advised for this: natively compiled, they call each other directly."
  (declare (indent 0))
  `(let ((start (float-time)))
     (unwind-protect
         (progn ,@body)
       (when (fboundp 'tmux-control--pause-log-took)
         (tmux-control--pause-log-took start (lambda () "qa.py's own request"))))))

(defun qa-watch-pauses ()
  "Note each pause of a second or more, if tmux-control can, and say whether it can."
  (when (fboundp 'tmux-control-pause-log-mode)
    (setq tmux-control-pause-log-threshold 1.0)
    (tmux-control-pause-log-mode 1)
    t))

(defun qa-take-pauses ()
  "The pauses noted since the last call, oldest first, but qa.py's own."
  (when (boundp 'tmux-control--pause-log)
    (let ((new (seq-take-while (lambda (note) (not (eq note qa--pauses-seen)))
                               tmux-control--pause-log)))
      (when tmux-control--pause-log
        (setq qa--pauses-seen (car tmux-control--pause-log)))
      (seq-remove (lambda (note) (string-match-p "qa\\.py's own request took" note))
                  (reverse new)))))

(defvar qa--commands-run (make-hash-table :test 'eq)
  "The commands journeys ran, through the command loop.")

(defun qa--note-command (command &rest _)
  "Note COMMAND, run from a key or a menu, for `qa-commands-not-run'."
  (when (and command (symbolp command))
    (puthash command t qa--commands-run)))

;; Keys and menus alike, transient's suffixes among them, run their
;; commands through `command-execute'.
(advice-add 'command-execute :before #'qa--note-command)

(defun qa-commands-run ()
  "The commands journeys ran, by name, for qa.py to keep across a restart."
  (let (names)
    (maphash (lambda (command _) (push (symbol-name command) names)) qa--commands-run)
    names))

(defun qa-commands-not-run ()
  "Roost's and tmux-control's commands no journey ran, by name.
The sweep runs commands too, but with what they reach outside their
view stubbed out, so it doesn't count here."
  (let (missing)
    (mapatoms (lambda (symbol)
                (let ((name (symbol-name symbol)))
                  (when (and (commandp symbol)
                             (string-match-p "\\`\\(?:roost\\|tmux-control\\)-" name)
                             (not (string-match-p "--" name))
                             ;; A major mode comes with the command that
                             ;; shows its buffer.
                             (not (and (string-suffix-p "-mode" name)
                                       (not (memq symbol minor-mode-list))))
                             (not (gethash symbol qa--commands-run)))
                    (push name missing)))))
    (sort missing #'string<)))

(defun qa-terminal-pid ()
  "The process id of the connection behind the selected terminal."
  (with-current-buffer (window-buffer (selected-window))
    (process-id (buffer-local-value 'tmux-control--process
                                    (or (and (boundp 'tmux-control--controller)
                                             (buffer-live-p tmux-control--controller)
                                             tmux-control--controller)
                                        (current-buffer))))))

(defun qa-take-errors ()
  "Every error since the last call, oldest first, and forget them."
  (prog1 (reverse (append (qa--messages-errors) qa--errors))
    (setq qa--errors nil)))

;;;; Input

(defun qa-keys (keys)
  "Press KEYS, in `kbd' notation, as from the keyboard."
  (setq unread-command-events (append unread-command-events (listify-key-sequence (kbd keys))))
  t)

(defun qa-type (text)
  "Type TEXT, as from the keyboard."
  (setq unread-command-events (append unread-command-events (string-to-list text)))
  t)

(defun qa--windows ()
  "The windows of every visible frame, those of the main frame first.
Child frames, such as the box a review note is written in, count."
  (cl-mapcan (lambda (frame) (window-list frame 'nomini))
             (sort (visible-frame-list)
                   (lambda (a b) (and (not (frame-parent a)) (frame-parent b))))))

(defun qa--find-button (label occurrence)
  "Window and position of button LABEL, its OCCURRENCE in visible windows."
  (let ((seen 0) found)
    (dolist (window (qa--windows) found)
      (unless found
        (with-current-buffer (window-buffer window)
          (let ((pos (window-start window)) (end (window-end window t)))
            ;; From the window's start itself: a button can begin there.
            (while (and (not found) (< pos end))
              (let ((next (next-single-char-property-change pos 'button nil end)))
                (when (and (get-char-property pos 'button)
                           (equal (buffer-substring-no-properties pos next) label))
                  (if (= seen occurrence) (setq found (cons window pos)) (cl-incf seen)))
                (setq pos next)))))))))

(defun qa-click (label &optional occurrence)
  "Click with the mouse on button LABEL, or its OCCURRENCE, counting from 0.
The button must be on screen.  Return nil when it isn't."
  (when-let* ((place (qa--find-button label (or occurrence 0)))
              ;; Its middle: a step in from its start is past a button of one
              ;; character, such as the sidebar's +.
              (posn (posn-at-point (+ (cdr place) (/ (length label) 2)) (car place))))
    (setq unread-command-events
          (append unread-command-events
                  (list (list 'down-mouse-1 posn) (list 'mouse-1 posn))))
    t))

(defun qa-click-text (text &optional mode)
  "Click with the mouse on the first TEXT on screen, in a window in MODE if given.
Return nil when it isn't on screen."
  (let (found)
    (dolist (window (qa--windows))
      (unless found
        (with-current-buffer (window-buffer window)
          (when (or (null mode) (derived-mode-p (intern mode)))
            (save-excursion
              (goto-char (window-start window))
              (when (search-forward text (window-end window t) t)
                (setq found (cons window (match-beginning 0)))))))))
    (when-let* ((posn (and found (posn-at-point (cdr found) (car found)))))
      (setq unread-command-events
            (append unread-command-events (list (list 'down-mouse-1 posn) (list 'mouse-1 posn))))
      t)))

(defun qa-click-terminal ()
  "Click in the first terminal on screen, as to type in it.
Return nil when no terminal is on screen."
  (when-let* ((window (seq-find (lambda (window) (qa--terminal (window-buffer window))) (qa--windows)))
              (posn (posn-at-point (window-start window) window)))
    (setq unread-command-events
          (append unread-command-events (list (list 'down-mouse-1 posn) (list 'mouse-1 posn))))
    t))

(defun qa-terminal-takes-mouse ()
  "Whether the program in the selected terminal takes the mouse."
  (let ((buffer (window-buffer (selected-window))))
    (and (qa--terminal buffer)
         (buffer-local-value 'eat--mouse-grabbing-type buffer)
         t)))

(defun qa-press-terminal ()
  "Press the mouse in the selected terminal, and never let go.
So a release the terminal never gets, as when tmux wasn't replying.
Return nil unless the selected window is a terminal."
  (let ((window (selected-window)))
    (when-let* (((qa--terminal (window-buffer window)))
                (posn (posn-at-point (window-start window) window)))
      (setq unread-command-events
            (append unread-command-events (list (list 'down-mouse-1 posn))))
      t)))

(defun qa-goto-row (name)
  "Move point to task NAME's row in the selected window, a list of tasks.
Return nil when it isn't there."
  (when-let* ((task (seq-find (lambda (task) (equal (roost--field task 'name) name)) (roost-tasks)))
              (row (with-current-buffer (window-buffer (selected-window))
                     (roost--task-row (roost--key task)))))
    (set-window-point (selected-window) row)
    t))

(defun qa-sidebar-to-top ()
  "Scroll each sidebar on screen to its top, as the mouse wheel would.
Point goes with it, as the wheel takes it along."
  (dolist (window (window-list-1 nil 'nomini 'visible))
    (when (eq (buffer-local-value 'major-mode (window-buffer window)) 'roost-sidebar-list-mode)
      (let ((top (with-current-buffer (window-buffer window) (point-min))))
        (set-window-start window top)
        (set-window-point window top))))
  t)

(defun qa-selected-task ()
  "The name of the task whose worktree holds the selected window's buffer, or nil."
  (with-current-buffer (window-buffer (selected-window))
    (when-let* ((task (roost--task-in-directory default-directory)))
      (roost--field task 'name))))

(defvar qa--slow-opens nil
  "(COUNT . SECONDS): hold the replies to the next COUNT tasks opened, SECONDS each.")

(defvar qa--held-replies 0
  "How many replies `qa-slow-opens' holds now.")

(defun qa-slow-opens (count seconds)
  "Hold the replies to the next COUNT tasks opened for SECONDS, as from a slow host."
  (setq qa--slow-opens (cons count seconds))
  t)

(defun qa-held-replies ()
  "How many replies `qa-slow-opens' holds now."
  qa--held-replies)

(defun qa--slow-request (args)
  "ARGS of `roost--request', its reply held if `qa-slow-opens' says so."
  (pcase-let ((`(,host ,action ,params ,success . ,rest) args))
    (if (not (and (equal action "inspect") success qa--slow-opens (> (car qa--slow-opens) 0)))
        args
      (cl-decf (car qa--slow-opens))
      (let ((seconds (cdr qa--slow-opens)))
        (cl-incf qa--held-replies)
        (append (list host action params
                      (lambda (&rest reply)
                        (run-at-time seconds nil (lambda ()
                                                   (cl-decf qa--held-replies)
                                                   (apply success reply)))))
                rest)))))

(advice-add 'roost--request :filter-args #'qa--slow-request)

(defvar qa--opens-started 0
  "How many times Roost has asked a host about a task it was opening.")

(defvar qa--opens-replied 0
  "How many of those questions the host has answered, either way.")

(defvar qa--opening nil
  "Non-nil while `roost-open-task' runs.")

(defun qa--note-opening (open &rest args)
  "Call OPEN, `roost-open-task', with ARGS, noting when its host replies."
  (let ((qa--opening t))
    (apply open args)))

(defun qa--count-open (args)
  "ARGS of `roost--request', counted until the host replies, if it opens a task.
A terminal already shown doesn't say an open is done: the reply can
still come and reconnect it, as after Roost opened the task it created."
  (pcase-let ((`(,host ,action ,params ,success ,failure) args))
    (if (not (and qa--opening (equal action "inspect") success failure))
        args
      (cl-incf qa--opens-started)
      (let* ((replied nil)
             (counted (lambda (callback)
                        (lambda (&rest reply)
                          (unwind-protect (apply callback reply)
                            (unless replied
                              (setq replied t)
                              (cl-incf qa--opens-replied)))))))
        (list host action params (funcall counted success) (funcall counted failure))))))

(advice-add 'roost-open-task :around #'qa--note-opening)
(advice-add 'roost--request :filter-args #'qa--count-open)

(defun qa-drafts ()
  "The text of each draft of a new task or a prompt."
  (let (drafts)
    (dolist (buffer (buffer-list) drafts)
      (with-current-buffer buffer
        (when (derived-mode-p 'roost-compose-mode 'roost-send-mode)
          (push (buffer-substring-no-properties (point-min) (point-max)) drafts))))))

(defun qa-forget-drafts ()
  "Kill every draft of a new task or a prompt, without asking."
  (dolist (buffer (buffer-list))
    (when (with-current-buffer buffer (derived-mode-p 'roost-compose-mode 'roost-send-mode))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))))
  t)

(defun qa-fresh-start ()
  "Leave one frame, its window on *scratch* beside Roost's side windows.
Each journey starts here, rather than amid the windows the last one left,
so that one going wrong doesn't take the rest with it.  A question left
open is dismissed first, with keys."
  ;; A mouse press left in a terminal: Eat holds every mouse event for it
  ;; until it sees the release.
  (when (bound-and-true-p eat--mouse-drag-transient-map-exit)
    (funcall eat--mouse-drag-transient-map-exit)
    (setq eat--mouse-drag-transient-map-exit nil
          eat--mouse-pressed-buttons nil
          eat--mouse-last-position nil))
  (dolist (frame (frame-list))
    (when (frame-parent frame) (delete-frame frame)))
  (dolist (frame (frame-list))
    (unless (or (eq frame (selected-frame)) (not (frame-visible-p frame)))
      (delete-frame frame)))
  (let ((main (seq-find (lambda (window) (not (window-parameter window 'window-side)))
                        (window-list nil 'nomini))))
    (select-window main)
    (delete-other-windows main)
    (switch-to-buffer "*scratch*"))
  (roost--redraw)
  t)

(defun qa-idle-p ()
  "Whether the input given so far has been taken."
  (and (null unread-command-events) (not executing-kbd-macro)))

;;;; What is on screen

(defun qa--overlay-strings (pos property ends)
  "PROPERTY strings of the overlays at POS, with ENDS those ending there.
Empty overlays at POS count among both."
  (let (strings)
    (dolist (overlay (delete-dups (append (overlays-in (max (point-min) (1- pos))
                                                       (min (point-max) (1+ pos)))
                                          ;; Empty ones at POS, which the first leaves out.
                                          (overlays-in pos pos))))
      (when (and (= (if ends (overlay-end overlay) (overlay-start overlay)) pos)
                 (stringp (overlay-get overlay property)))
        (push (overlay-get overlay property) strings)))
    strings))

(defun qa--shown (start end)
  "The text from START to END as shown: what is invisible left out,
strings that overlays add put in, and the text properties kept."
  (let ((pieces nil) (pos start))
    (while (<= pos end)
      (setq pieces (append (qa--overlay-strings pos 'after-string t) pieces))
      (when (< pos end)
        (setq pieces (append (qa--overlay-strings pos 'before-string nil) pieces))
        (unless (invisible-p pos)
          (push (buffer-substring pos (1+ pos)) pieces)))
      (cl-incf pos))
    (apply #'concat (nreverse pieces))))

(defun qa--visible-text (window)
  "WINDOW's text from its start to its end, as shown, line prefixes included."
  (with-current-buffer (window-buffer window)
    (let* ((start (window-start window))
           (end (min (point-max) (or (window-end window t) (point-max))))
           (lines nil))
      ;; Prefixes are display properties; show them as text.
      (dolist (line (split-string (qa--shown start end) "\n"))
        (let ((prefix (and (> (length line) 0) (get-text-property 0 'line-prefix line))))
          (push (concat (if (stringp prefix) prefix "") (substring-no-properties line)) lines)))
      (string-join (nreverse lines) "\n"))))

(defun qa--roost-buffer-p (buffer)
  "Whether BUFFER is one of Roost's views."
  (with-current-buffer buffer
    (derived-mode-p 'roost-task-info-mode 'roost-dashboard-mode 'roost-search-mode
                    'roost-compose-mode 'roost-send-mode)))

(defun qa--overflow (window)
  "Lines of Roost's WINDOW wider than it, as shown, with the window's width.
Return nil, or ((width . PIXELS) (lines . [[LINE PIXELS] ...])).  A line
Emacs wraps fits; one it cuts at the edge, as with `truncate-lines',
doesn't."
  (with-current-buffer (window-buffer window)
    (when (and (qa--roost-buffer-p (current-buffer))
               (or truncate-lines (truncated-partial-width-window-p window)))
      (let ((width (window-body-width window t)) (over nil))
        (save-excursion
          (goto-char (window-start window))
          (while (< (point) (min (point-max) (or (window-end window t) (point-max))))
            (let* ((start (point))
                   (end (line-end-position))
                   ;; With t, past the window's edge too.
                   (pixels (car (window-text-pixel-size window start end t))))
              (when (> pixels width)
                (push (vector (buffer-substring-no-properties start end) pixels) over)))
            (forward-line 1)))
        (when over `((width . ,width) (lines . ,(vconcat (nreverse over)))))))))

(defun qa--terminal (buffer)
  "BUFFER's tmux session as HOST/SOCKET/SESSION, if it is a terminal."
  (with-current-buffer buffer
    (when (and (derived-mode-p 'tmux-control-mode) (fboundp 'tmux-control-buffer-session)
               (tmux-control-buffer-session))
      (format "%s/%s/%s" (or (tmux-control-buffer-host) "local")
              (tmux-control-buffer-socket-name) (tmux-control-buffer-session)))))

(defun qa-terminal-screen (buffer)
  "The live screen of terminal BUFFER, a buffer or its name, as lines.
Right-trimmed, without the trailing blank ones, as `capture-pane' gives
them; nil when BUFFER isn't a terminal."
  (when-let* ((buffer (get-buffer buffer)))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'tmux-control-mode) (bound-and-true-p tmux-control--terminal)
                 (eat-term-live-p tmux-control--terminal))
        ;; From the start of the line it begins on, which the window shows
        ;; too: a screen starting partway into a line of history must not
        ;; read as tmux's.
        (let ((start (save-excursion (goto-char (eat-term-display-beginning tmux-control--terminal))
                                     (line-beginning-position)))
              (end (eat-term-end tmux-control--terminal))
              lines)
          ;; Without the invisible cell Eat puts after a wide character.
          (dolist (line (split-string (apply #'string
                                             (mapcar #'char-after
                                                     (seq-remove (lambda (i) (get-text-property i 'invisible))
                                                                 (number-sequence start (1- end)))))
                                      "\n"))
            (push (string-trim-right line) lines))
          (while (and lines (string-empty-p (car lines))) (pop lines))
          (vconcat (nreverse lines)))))))

(defun qa--history-shown (window)
  "How many lines of history terminal WINDOW shows above its live screen."
  (with-current-buffer (window-buffer window)
    (if (and (derived-mode-p 'tmux-control-mode) (bound-and-true-p tmux-control--terminal)
             (eat-term-live-p tmux-control--terminal))
        (let ((screen (save-excursion (goto-char (eat-term-display-beginning tmux-control--terminal))
                                      (line-beginning-position))))
          (if (< (window-start window) screen) (count-lines (window-start window) screen) 0))
      0)))

(defun qa--line (window line)
  "WINDOW's LINE, `mode-line-format' or `header-line-format', or nil.
A window parameter of that name takes the buffer's place, as in redisplay."
  (let ((format (or (window-parameter window line)
                    (buffer-local-value line (window-buffer window)))))
    (and format (not (eq format 'none))
         (with-current-buffer (window-buffer window)
           (format-mode-line format nil window)))))

(defun qa--tabs (window)
  "WINDOW's header line as shown, the highlighted tab in [brackets], or nil."
  (with-current-buffer (window-buffer window)
    (when-let* (((derived-mode-p 'tmux-control-mode))
                (line (qa--line window 'header-line-format)))
      (let ((shown "") (start 0))
        (while (< start (length line))
          (let ((end (or (next-single-property-change start 'face line) (length line))))
            (setq shown (concat shown
                                (if (memq 'tmux-control-tab-active
                                          (ensure-list (get-text-property start 'face line)))
                                    (format "[%s]" (string-trim (substring-no-properties line start end)))
                                  (substring-no-properties line start end))))
            (setq start end)))
        (string-trim shown)))))

(defun qa--frame-id (frame)
  "An id for FRAME's root frame, the one a child frame such as a note box is in."
  (format "%x" (sxhash-eq (or (frame-parent frame) frame))))

(defun qa--task-info (task)
  "TASK as qa-screen reports it, or nil."
  (when task
    `((name . ,(roost--field task 'name))
      (key . ,(format "%s/%s" (or (roost--field task 'host) "local") (roost--field task 'id)))
      (terminal . ,(format "%s/%s/%s" (or (roost--field task 'host) "local")
                           (roost--field task 'socket) (roost--field task 'session)))
      ;; The agent's own pane.
      (pane . ,(roost--field task 'paneId)))))

(defvar qa--questions-asked 0
  "How many questions the minibuffer has asked.")

(defvar-local qa--question nil
  "Which question this minibuffer asks, counting from the first asked.
A minibuffer's buffer is used again for the next question at its depth.")

(defun qa--question-asked ()
  "Number the question the minibuffer asks now, for `qa--questions'."
  (setq qa--question (cl-incf qa--questions-asked)))

(add-hook 'minibuffer-setup-hook #'qa--question-asked)

(defun qa--questions ()
  "The questions open in the minibuffer, the first asked first, each ((id . N) (prompt . TEXT)).
On screen or not: a completion popup can hide one you leave.  N tells a
question from another of the same prompt asked after it."
  (let (questions)
    (dolist (buffer (buffer-list))
      (when (and (minibufferp buffer t)
                 (string-match " \\*Minibuf-\\([0-9]+\\)\\*" (buffer-name buffer)))
        (push (cons (string-to-number (match-string 1 (buffer-name buffer)))
                    (with-current-buffer buffer
                      `((id . ,qa--question)
                        (prompt . ,(buffer-substring-no-properties (point-min) (minibuffer-prompt-end))))))
              questions)))
    (mapcar #'cdr (sort questions (lambda (a b) (< (car a) (car b)))))))

(defun qa-screen ()
  "What is on screen now, as JSON."
  (let ((frame (or (frame-parent) (selected-frame))))
    (json-encode
     `((frame . ((columns . ,(frame-width frame)) (lines . ,(frame-height frame))
                 (pixels . [,(frame-pixel-width frame) ,(frame-pixel-height frame)])))
       (selected . ,(buffer-name (window-buffer (selected-window))))
       (at . ,(with-current-buffer (window-buffer (selected-window))
                (when-let* ((button (button-at (window-point))))
                  (button-label button))))
       (prompt . ,(minibuffer-prompt))
       ;; Every question open, the first asked first, whether you are in
       ;; one, and what Roost holds back until they are done.
       (questions . ,(vconcat (qa--questions)))
       (in-question . ,(if (minibufferp (window-buffer (selected-window)) t) t :json-false))
       (held . ,roost--held-for-minibuffer)
       (opens . ((started . ,qa--opens-started) (replied . ,qa--opens-replied)))
       (minibuffer . ,(when (active-minibuffer-window)
                        (with-current-buffer (window-buffer (active-minibuffer-window))
                          (buffer-substring-no-properties (minibuffer-prompt-end) (point-max)))))
       (echo . ,(current-message))
       (windows
        . ,(vconcat
            (mapcar (lambda (window)
                      (let ((buffer (window-buffer window)))
                        `((buffer . ,(buffer-name buffer))
                          (mode . ,(symbol-name (buffer-local-value 'major-mode buffer)))
                          (roost . ,(if (qa--roost-buffer-p buffer) t :json-false))
                          (selected . ,(if (eq window (selected-window)) t :json-false))
                          (side . ,(window-parameter window 'window-side))
                          (terminal . ,(qa--terminal buffer))
                          (history . ,(qa--history-shown window))
                          (pane . ,(with-current-buffer buffer
                                     (and (derived-mode-p 'tmux-control-mode) (fboundp 'tmux-control-active-pane)
                                          (tmux-control-active-pane))))
                          (tabs . ,(qa--tabs window))
                          (mode-line . ,(substring-no-properties
                                         (or (qa--line window 'mode-line-format) "")))
                          (child . ,(if (frame-parent (window-frame window)) t :json-false))
                          (frame . ,(qa--frame-id (window-frame window)))
                          (columns . ,(window-body-width window))
                          (total . ,(window-total-width window))
                          (lines . ,(window-body-height window))
                          (text . ,(qa--visible-text window))
                          (overflow . ,(qa--overflow window)))))
                    (qa--windows))))
       ;; The main frame's, though a child frame such as a note box is selected.
       (sidebar-width . ,roost-sidebar-width)
       ;; The task the sidebar marks as yours, as drawn.
       (marked . ,(when-let* ((sidebar (get-buffer roost--sidebar-buffer)))
                    (with-current-buffer sidebar
                      (save-excursion
                        (goto-char (point-min))
                        ;; The row behind its band.
                        (when-let* ((match (text-property-search-forward
                                            'face 'roost-current
                                            (lambda (face value) (memq face (ensure-list value)))))
                                    (key (get-text-property (prop-match-beginning match) 'roost-task)))
                          (format "%s/%s" (or (car key) "local") (cadr key)))))))
       (task . ,(qa--task-info (with-selected-frame frame (roost--frame-task))))
       ;; Each frame's task, by its id: the checks hold per frame.
       (frames . ,(let (frames)
                    (dolist (each (visible-frame-list) frames)
                      (unless (frame-parent each)
                        (push (cons (intern (qa--frame-id each))
                                    (or (qa--task-info (with-selected-frame each (roost--frame-task)))
                                        :json-false))
                              frames)))))
       ;; With a workspace per task, the current one and, with tab-bar, all.
       (workspace . ,(with-selected-frame frame (roost--current-workspace)))
       (workspaces . ,(vconcat (with-selected-frame frame
                                 (when (eq (roost--workspace-backend) 'tab-bar) (roost--tabs)))))
       (tasks . ,(vconcat (mapcar (lambda (task)
                                    `((name . ,(roost--field task 'name))
                                      (key . ,(format "%s/%s" (or (roost--field task 'host) "local")
                                                      (roost--field task 'id)))
                                      (status . ,(roost--attention-status task))))
                                  (roost-tasks))))
       (buffers . ,(vconcat (seq-filter (lambda (name) (member name '("*Backtrace*" "*Warnings*")))
                                        (mapcar #'buffer-name (buffer-list)))))))))

;;;; Running the sweep here

(defun qa-sweep ()
  "Run test/roost-sweep.el's rules in a frame of their own here, where
text is measured in pixels.  Return how many ran and the problems, as JSON."
  (let ((frame (make-frame '((visibility . nil) (width . 160) (height . 48))))
        (stats nil))
    (unwind-protect
        (with-selected-frame frame
          (let ((inhibit-message t))
            (setq stats (qa--own-work (ert-run-tests-batch "^roost-sweep-")))))
      (delete-frame frame)
      ;; The sweep draws its sample tasks in Roost's own buffers, the
      ;; sidebar's among them: draw yours again.
      (roost--redraw))
    (json-encode
     `((ran . ,(length (ert--stats-tests stats)))
       (problems
        . ,(vconcat
            (delq nil (mapcar (lambda (test)
                          (let ((result (ert-test-most-recent-result test)))
                            (unless (ert-test-result-expected-p test result)
                              `((test . ,(symbol-name (ert-test-name test)))
                                (condition . ,(format "%S" (and (ert-test-result-with-condition-p result)
                                                                 (ert-test-result-with-condition-condition result))))))))
                              (append (ert--stats-tests stats) nil)))))))))

;;;; Focus

;; Child frames and new tasks raise and focus their frame; this Emacs
;; runs while you use others, and must not take your typing.
(advice-add 'select-frame-set-input-focus :override
            (lambda (frame &rest _) (select-frame frame)))
(advice-add 'raise-frame :override #'ignore)

;; Yet it acts as one you are looking at, as you would be while pressing
;; its keys: Roost marks an agent seen only then.
(advice-add 'frame-focus-state :override (lambda (&rest _) t))

(provide 'qa)

;;; qa.el ends here
