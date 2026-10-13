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

(defun qa--find-button (label occurrence)
  "Window and position of button LABEL, its OCCURRENCE in visible windows."
  (let ((seen 0) found)
    (dolist (window (window-list nil 'nomini) found)
      (unless found
        (with-current-buffer (window-buffer window)
          (let ((pos (window-start window)) (end (window-end window t)))
            (while (and (not found) (setq pos (next-single-char-property-change pos 'button nil end))
                        (< pos end))
              (when (and (get-char-property pos 'button)
                         (equal (buffer-substring-no-properties
                                 pos (next-single-char-property-change pos 'button nil end))
                                label))
                (if (= seen occurrence) (setq found (cons window pos)) (cl-incf seen))))))))))

(defun qa-click (label &optional occurrence)
  "Click with the mouse on button LABEL, or its OCCURRENCE, counting from 0.
The button must be on screen.  Return nil when it isn't."
  (when-let* ((place (qa--find-button label (or occurrence 0)))
              (posn (posn-at-point (1+ (cdr place)) (car place))))
    (setq unread-command-events
          (append unread-command-events
                  (list (list 'down-mouse-1 posn) (list 'mouse-1 posn))))
    t))

(defun qa-idle-p ()
  "Whether the input given so far has been taken."
  (and (null unread-command-events) (not executing-kbd-macro)))

;;;; What is on screen

(defun qa--visible-text (window)
  "WINDOW's text from its start to its end, as shown, line prefixes included."
  (with-current-buffer (window-buffer window)
    (let* ((start (window-start window))
           (end (min (point-max) (or (window-end window t) (point-max))))
           (text (buffer-substring start end))
           (lines nil))
      ;; Prefixes are display properties; show them as text.
      (dolist (line (split-string text "\n"))
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

(defun qa-screen ()
  "What is on screen now, as JSON."
  (let ((frame (selected-frame)))
    (json-encode
     `((frame . ((columns . ,(frame-width frame)) (lines . ,(frame-height frame))
                 (pixels . [,(frame-pixel-width frame) ,(frame-pixel-height frame)])))
       (selected . ,(buffer-name (window-buffer (selected-window))))
       (prompt . ,(minibuffer-prompt))
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
                          (columns . ,(window-body-width window))
                          (lines . ,(window-body-height window))
                          (text . ,(qa--visible-text window))
                          (overflow . ,(qa--overflow window)))))
                    (window-list frame 'nomini))))
       (tasks . ,(vconcat (mapcar (lambda (task)
                                    `((name . ,(roost--field task 'name))
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
            (setq stats (ert-run-tests-batch "^roost-sweep-"))))
      (delete-frame frame))
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
