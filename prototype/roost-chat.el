;;; roost-chat.el --- Talk to Claude Code, typeset -*- lexical-binding: t; -*-

;; A prototype.  It runs Claude Code the way Claude's desktop app does:
;; `claude' exchanging JSON messages on its standard input and output,
;; the protocol of Anthropic's Agent SDK.  The conversation is shown
;; with roost-reader's typesetting: replies stream in as Claude writes
;; them, tool calls fold to a line, and diagrams draw where Claude
;; shows them.  You write in a field docked below.  Claude's requests
;; to use a tool, its questions and its plans appear in the
;; conversation, answered with a key or a click.

;;; Code:

(require 'roost-reader)

(defgroup roost-chat nil
  "Talk to Claude Code, typeset."
  :group 'roost)

(defcustom roost-chat-program "claude"
  "The Claude Code command."
  :type 'string)

(defcustom roost-chat-model nil
  "The model a conversation starts with, or nil for Claude Code's default."
  :type '(choice (const :tag "Claude Code's default" nil) string))

(defcustom roost-chat-diagrams t
  "Whether Claude can show diagrams, with the show_diagram tool."
  :type 'boolean)

(defconst roost-chat--diagram-server
  (expand-file-name "roost_diagram_mcp.py"
                    (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "The MCP server that gives Claude the show_diagram tool.")

(defface roost-chat-request
  '((((background dark)) :background "#27251e" :extend t)
    (t :background "#faf5e6" :extend t))
  "A request waiting for your answer.")

(defface roost-chat-request-title '((t :weight bold)) "What a request asks.")

(defface roost-chat-button
  '((((background dark)) :background "#373c47" :box (:line-width (10 . 4) :color "#373c47"))
    (t :background "#e8e4d9" :box (:line-width (10 . 4) :color "#e8e4d9")))
  "A choice.")

(defface roost-chat-button-yes
  '((((background dark)) :background "#2d4b38" :box (:line-width (10 . 4) :color "#2d4b38"))
    (t :background "#d5eadb" :box (:line-width (10 . 4) :color "#d5eadb")))
  "The choice that lets Claude go ahead.")

(defface roost-chat-button-no
  '((((background dark)) :background "#4d3131" :box (:line-width (10 . 4) :color "#4d3131"))
    (t :background "#f3dbd7" :box (:line-width (10 . 4) :color "#f3dbd7")))
  "The choice that stops Claude.")

(defface roost-chat-key '((t :inherit shadow :height 0.8)) "Keys that answer a request.")
(defface roost-chat-status '((t :inherit shadow :slant italic)) "What Claude is doing.")
(defface roost-chat-settled `((t :inherit shadow :family ,roost-reader-mono :height 0.8))
  "A request you answered.")

(defface roost-chat-input
  `((((background dark)) :family ,roost-reader-serif :height 165 :background "#22252c")
    (t :family ,roost-reader-serif :height 165 :background "#f3f1eb"))
  "The field you write in.")

(defface roost-chat-control `((t :family ,roost-reader-mono :height 0.8 :inherit shadow))
  "The controls under the field.")

;;;; State

(defvar-local roost-chat--process nil "The Claude Code process.")
(defvar-local roost-chat--input nil "The field you write in.")
(defvar-local roost-chat--conversation nil "In the field: its conversation.")
(defvar-local roost-chat--partial "" "Output not yet ending in a newline.")
(defvar-local roost-chat--directory nil "Where Claude works.")
(defvar-local roost-chat--session nil "Claude Code's session id.")
(defvar-local roost-chat--model nil "The model's id.")
(defvar-local roost-chat--mode "default" "The permission mode.")
(defvar-local roost-chat--models nil "The models to choose from.")
(defvar-local roost-chat--commands nil "Slash commands, as (NAME . DESCRIPTION).")
(defvar-local roost-chat--state 'starting "One of starting, ready, working, waiting or stopped.")
(defvar-local roost-chat--activity nil "What Claude says it is doing.")
(defvar-local roost-chat--since nil "When Claude began working.")
(defvar-local roost-chat--live nil "Start of the reply being written, or nil.")
(defvar-local roost-chat--live-text "" "The reply written so far.")
(defvar-local roost-chat--live-timer nil "Timer redrawing the reply being written.")
(defvar-local roost-chat--requests nil "Requests waiting for you, oldest first: (ID . PLIST).")
(defvar-local roost-chat--callbacks nil "Replies awaited to our requests: (ID . FUNCTION).")
(defvar-local roost-chat--counter 0 "Requests sent so far.")
(defvar-local roost-chat--status nil "Overlay at the end saying what Claude is doing.")
(defvar-local roost-chat--ticker nil "Timer animating the status.")
(defvar-local roost-chat--attach nil
  "For a Roost task: a function returning the argv attaching to its agent.")
(defvar-local roost-chat--task-key nil "The Roost task this conversation is, if any.")
(defvar-local roost-chat--title nil "The conversation's name and a line about it: (NAME . LINE).")
(defvar-local roost-chat--keeps-answers nil
  "Whether the holder attached to keeps how you answered Claude's requests.")
(defvar-local roost-chat--where nil "Where Claude runs, for a Roost task: its host.")
(defvar-local roost-chat--seen nil "Ids of the messages shown, to drop repeats when attaching.")

(declare-function roost--key "roost" (task))
(declare-function roost--field "roost" (task field))
(declare-function roost--host-label "roost" (host))
(declare-function roost--remote-directory "roost" (task))
(declare-function roost--attach-command "roost" (task))

(defmacro roost-chat--following (&rest body)
  "Run BODY, an edit, keeping windows that were at the end there."
  (declare (indent 0) (debug t))
  `(let* ((inhibit-read-only t)
          (following (seq-filter (lambda (window)
                                   (>= (window-point window) (max (point-min) (1- (point-max)))))
                                 (get-buffer-window-list nil nil t))))
     (save-excursion ,@body)
     (roost-chat--place-status)
     (dolist (window following) (set-window-point window (point-max)))))

(defmacro roost-chat--at-end (&rest body)
  "Run BODY at the end of the conversation, keeping windows there at its end."
  (declare (indent 0) (debug t))
  `(roost-chat--following (goto-char (point-max)) ,@body))

;;;; Talking to Claude Code

(defun roost-chat--send (message)
  "Send MESSAGE, an alist, to Claude Code."
  (when (process-live-p roost-chat--process)
    (process-send-string roost-chat--process
                         (concat (json-serialize message :null-object :null :false-object :false)
                                 "\n"))))

(defun roost-chat--control (request &optional callback)
  "Send Claude Code the control REQUEST; call CALLBACK with its reply."
  (let ((id (format "roost_%d" (setq roost-chat--counter (1+ roost-chat--counter)))))
    (when callback (push (cons id callback) roost-chat--callbacks))
    (roost-chat--send `((type . "control_request") (request_id . ,id) (request . ,request)))))

(defun roost-chat--respond (id response &optional note)
  "Answer Claude Code's request ID with RESPONSE.
A Roost task's holder keeps NOTE, the answer in words, to show it to
every Emacs attached and again after a reconnect."
  (roost-chat--send `((type . "control_response")
                      (response . ((subtype . "success") (request_id . ,id) (response . ,response)))
                      ,@(when (and note roost-chat--keeps-answers) `((roost_note . ,note))))))

(defun roost-chat--parse (line &optional exact)
  "LINE, a JSON object, as an alist.
With EXACT, keep arrays, nulls and falses, to send parts back unchanged."
  (if exact
      (json-parse-string line :object-type 'alist :array-type 'array
                         :null-object :null :false-object :false)
    (json-parse-string line :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defun roost-chat--filter (buffer output)
  "Handle OUTPUT from the Claude Code of conversation BUFFER, line by line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((lines (split-string (concat roost-chat--partial output) "\n")))
        (setq roost-chat--partial (car (last lines)))
        (dolist (line (butlast lines))
          (unless (string-blank-p line)
            (with-demoted-errors "Roost chat: %S"
              (roost-chat--handle line))))))))

(defun roost-chat--handle (line)
  "Handle LINE, one message from Claude Code."
  (let* ((message (roost-chat--parse line))
         (nested (alist-get 'parent_tool_use_id message)))
    ;; A subagent's own messages carry the call that started it.
    (pcase (and (not (roost-chat--repeat-p message)) (alist-get 'type message))
      ("roost_history" (roost-chat--on-history (alist-get 'entry message)))
      ("roost_attached" (roost-chat--on-attached message))
      ("roost_answer" (roost-chat--on-answer (alist-get 'tool_use_id message) (alist-get 'note message)))
      ("roost_detached" (roost-chat--at-end
                          (insert (propertize (format "\n%s\n" (alist-get 'error message))
                                              'face 'roost-reader-note))))
      ("system" (roost-chat--on-system message))
      ("stream_event" (unless nested (roost-chat--on-stream (alist-get 'event message))))
      ("assistant" (unless nested (roost-chat--on-reply message)))
      ("user" (unless nested (roost-chat--on-results message)))
      ("result" (roost-chat--on-result message))
      ("control_request" (roost-chat--on-request message (roost-chat--parse line t)))
      ("control_cancel_request" (roost-chat--settle (alist-get 'request_id message)
                                                    "Claude withdrew this request"))
      ("control_response" (roost-chat--on-response message)))))

(defun roost-chat--repeat-p (message)
  "Whether MESSAGE was shown already, with the conversation so far."
  (when-let* (((member (alist-get 'type message) '("assistant" "user")))
              (id (alist-get 'uuid message)))
    (or (gethash id roost-chat--seen)
        (ignore (puthash id t roost-chat--seen)))))

(defun roost-chat--on-history (entry)
  "Show ENTRY, part of the conversation so far, from its transcript."
  (when-let* ((id (alist-get 'uuid entry)))
    (puthash id t roost-chat--seen))
  (roost-chat--at-end (roost-reader--insert-entry entry)))

(defun roost-chat--on-attached (message)
  "Note what MESSAGE says of the agent just attached to: whether it works."
  (setq roost-chat--session (or (alist-get 'session message) roost-chat--session)
        roost-chat--keeps-answers (alist-get 'answers message))
  (roost-chat--set-state (if (alist-get 'working message) 'working 'ready)))

(defun roost-chat--on-response (message)
  "Handle MESSAGE, Claude Code's reply to one of our requests."
  (let* ((response (alist-get 'response message))
         (id (alist-get 'request_id response))
         (callback (cdr (assoc id roost-chat--callbacks))))
    (setq roost-chat--callbacks (assoc-delete-all id roost-chat--callbacks))
    (if (equal (alist-get 'subtype response) "error")
        (message "Claude Code: %s" (alist-get 'error response))
      (when callback (funcall callback (alist-get 'response response))))))

(defun roost-chat--initialized (response)
  "Keep what Claude Code's RESPONSE to starting up offers."
  (setq roost-chat--models (alist-get 'models response)
        roost-chat--commands (mapcar (lambda (command)
                                       (cons (alist-get 'name command)
                                             (alist-get 'description command)))
                                     (alist-get 'commands response))
        roost-chat--mode (or (alist-get 'current_permission_mode response) roost-chat--mode))
  ;; The model is named once Claude first replies; until then, the one asked for.
  (unless roost-chat--model
    (setq roost-chat--model
          (alist-get 'resolvedModel
                     (seq-find (lambda (model) (equal (alist-get 'value model) (or roost-chat-model "default")))
                               roost-chat--models))))
  (when (eq roost-chat--state 'starting) (roost-chat--set-state 'ready))
  (roost-chat--refresh-controls))

;;;; The conversation

(defconst roost-chat--spinner ["✻" "✳" "✶" "✢" "·" "✢" "✶" "✳"]
  "Frames of the working indicator.")

(defun roost-chat--elapsed ()
  "How long Claude has been working, briefly."
  (let ((seconds (truncate (- (float-time) (or roost-chat--since (float-time))))))
    (if (< seconds 60)
        (format "%ds" seconds)
      (format "%dm %02ds" (/ seconds 60) (% seconds 60)))))

(defun roost-chat--status-text ()
  "What the end of the conversation says about Claude."
  (pcase roost-chat--state
    ('working
     (propertize (format "\n%s  %s · %s\n"
                         (aref roost-chat--spinner (% (truncate (* 5 (float-time)))
                                                      (length roost-chat--spinner)))
                         (or roost-chat--activity "Working")
                         (roost-chat--elapsed))
                 'face 'roost-chat-status))
    ('waiting (propertize "\n●  Waiting for your answer\n" 'face 'roost-chat-status))
    ('starting (propertize "\nStarting Claude Code…\n" 'face 'roost-chat-status))
    ('stopped (propertize "\nClaude Code has stopped. g starts it again.\n" 'face 'roost-chat-status))
    ('detached (propertize "\nNot connected to Claude. g connects again.\n" 'face 'roost-chat-status))))

(defun roost-chat--place-status ()
  "Show what Claude is doing at the end of the conversation."
  (unless (overlayp roost-chat--status)
    (setq roost-chat--status (make-overlay (point-max) (point-max))))
  (move-overlay roost-chat--status (point-max) (point-max))
  (overlay-put roost-chat--status 'after-string (roost-chat--status-text)))

(defun roost-chat--set-state (state)
  "Note that Claude is now in STATE."
  (setq roost-chat--state state)
  (pcase state
    ((or 'working 'waiting) (setq roost-chat--since (or roost-chat--since (float-time))))
    (_ (setq roost-chat--since nil roost-chat--activity nil)))
  (when (timerp roost-chat--ticker) (cancel-timer roost-chat--ticker))
  (setq roost-chat--ticker nil)
  (when (eq state 'working)
    (let ((buffer (current-buffer)) timer)
      (setq timer (run-with-timer 0.2 0.2 (lambda ()
                                            (if (buffer-live-p buffer)
                                                (with-current-buffer buffer (roost-chat--place-status))
                                              (cancel-timer timer))))
            roost-chat--ticker timer)))
  (roost-chat--place-status)
  (roost-chat--refresh-controls))

(defun roost-chat--on-system (message)
  "Handle MESSAGE, news about the session."
  (pcase (alist-get 'subtype message)
    ("init"
     (setq roost-chat--session (alist-get 'session_id message)
           roost-chat--model (alist-get 'model message)
           roost-chat--mode (or (alist-get 'permissionMode message) roost-chat--mode))
     (roost-chat--refresh-controls))
    ("status"
     (pcase (alist-get 'status message)
       ("requesting" (unless (eq roost-chat--state 'waiting) (roost-chat--set-state 'working)))
       ("compacting" (setq roost-chat--activity "Compacting the conversation"))))
    ("task_summary"
     (setq roost-chat--activity (alist-get 'detail message))
     (roost-chat--place-status))
    ("compact_boundary"
     (roost-chat--at-end
       (insert (propertize "\nThe conversation so far was compacted.\n" 'face 'roost-reader-note))))))

(defun roost-chat--on-stream (event)
  "Handle EVENT, part of a reply as Claude writes it."
  (pcase (alist-get 'type event)
    ("content_block_start"
     (let ((block (alist-get 'content_block event)))
       (pcase (alist-get 'type block)
         ("text" (roost-chat--at-end
                   (roost-reader--paragraph-break)
                   (setq roost-chat--live (point-marker) roost-chat--live-text "")))
         ("thinking" (setq roost-chat--activity "Thinking"))
         ("tool_use" (setq roost-chat--activity (roost-chat--doing (alist-get 'name block) nil))))))
    ("content_block_delta"
     (let ((delta (alist-get 'delta event)))
       (when (and roost-chat--live (equal (alist-get 'type delta) "text_delta"))
         (setq roost-chat--live-text (concat roost-chat--live-text (alist-get 'text delta)))
         (unless (timerp roost-chat--live-timer)
           (let ((buffer (current-buffer)))
             (setq roost-chat--live-timer
                   (run-with-timer 0.06 nil (lambda ()
                                              (when (buffer-live-p buffer)
                                                (with-current-buffer buffer
                                                  (setq roost-chat--live-timer nil)
                                                  (roost-chat--draw-live)))))))))))))

(defun roost-chat--draw-live ()
  "Draw the reply Claude is writing, its Markdown rendered as far as it goes."
  (when roost-chat--live
    (roost-chat--at-end
      (delete-region roost-chat--live (point-max))
      (roost-reader--insert-markdown (string-trim-left roost-chat--live-text)))))

(defun roost-chat--doing (name input)
  "What Claude is doing with tool NAME and INPUT, for the status."
  (cond ((string-suffix-p "show_diagram" name) "Drawing a diagram")
        ((equal name "AskUserQuestion") "Asking you")
        ((equal name "ExitPlanMode") "Proposing a plan")
        (input (string-remove-prefix "$ " (roost-reader--tool-summary name input t)))
        (t (format "Using %s" name))))

(defun roost-chat--on-reply (message)
  "Handle MESSAGE, a finished part of Claude's reply."
  (dolist (block (alist-get 'content (alist-get 'message message)))
    (pcase (alist-get 'type block)
      ("text"
       (when (timerp roost-chat--live-timer) (cancel-timer roost-chat--live-timer))
       (setq roost-chat--live-timer nil)
       (roost-chat--at-end
         (if roost-chat--live
             (delete-region roost-chat--live (point-max))
           (roost-reader--paragraph-break))
         (roost-reader--insert-markdown (string-trim (alist-get 'text block))))
       (when roost-chat--live (set-marker roost-chat--live nil))
       (setq roost-chat--live nil roost-chat--live-text ""))
      ("tool_use"
       (let ((name (alist-get 'name block)))
         ;; Its question or plan shows as a request instead.
         (unless (member name '("AskUserQuestion" "ExitPlanMode"))
           (roost-chat--at-end (roost-reader--insert-tool block)))
         (setq roost-chat--activity (roost-chat--doing name (alist-get 'input block))))))))

(defun roost-chat--on-results (message)
  "Handle MESSAGE, the results of Claude's tool calls."
  (let ((content (alist-get 'content (alist-get 'message message))))
    (if (alist-get 'isReplay message)
        ;; What you wrote, here or in another Emacs, as Claude takes it.
        (let ((text (if (stringp content)
                        content
                      (mapconcat (lambda (block) (or (alist-get 'text block) "")) content "\n"))))
          (when (roost-reader--user-text-p text)
            (roost-chat--at-end (roost-reader--insert-prompt text))))
      (dolist (block (and (listp content) content))
        (pcase (alist-get 'type block)
          ("tool_result" (let ((inhibit-read-only t)) (roost-reader--attach-result block)))
          ("text"
           (when (string-prefix-p "[Request interrupted" (alist-get 'text block))
             (roost-chat--at-end
               (insert (propertize "\nYou stopped Claude.\n" 'face 'roost-reader-note))))))))))

(defun roost-chat--on-result (message)
  "Handle MESSAGE, the end of Claude's turn."
  ;; A stopped reply ends where it was; the next one starts afresh.
  (when (timerp roost-chat--live-timer) (cancel-timer roost-chat--live-timer))
  (when roost-chat--live (roost-chat--draw-live) (set-marker roost-chat--live nil))
  (setq roost-chat--live nil roost-chat--live-timer nil roost-chat--live-text "")
  (when (and (alist-get 'is_error message)
             (not (member (alist-get 'subtype message) '("error_during_execution"))))
    (roost-chat--at-end
      (insert (propertize (format "\n%s\n" (or (alist-get 'result message)
                                               "Claude's turn ended with an error."))
                          'face 'roost-reader-note))))
  (roost-chat--set-state 'ready)
  (unless (get-buffer-window (current-buffer) 'visible)
    (message "Claude has finished in %s"
             (file-name-nondirectory (directory-file-name roost-chat--directory)))))

;;;; Requests: tools, questions and plans

(defun roost-chat--on-request (message exact)
  "Handle MESSAGE, a request from Claude Code; EXACT is it parsed to send back."
  (let ((id (alist-get 'request_id message))
        (request (alist-get 'request message))
        (exact (alist-get 'request exact)))
    (if (not (equal (alist-get 'subtype request) "can_use_tool"))
        (roost-chat--send `((type . "control_response")
                            (response . ((subtype . "error") (request_id . ,id)
                                         (error . "Roost does not handle this request")))))
      (pcase (alist-get 'tool_name request)
        ("AskUserQuestion" (roost-chat--ask id request exact))
        ("ExitPlanMode" (roost-chat--plan id request exact))
        (_ (roost-chat--permission id request exact)))
      ;; Another Emacs's answer names the tool call, not this request.
      (when-let* ((entry (assoc id roost-chat--requests)))
        (setcdr entry (plist-put (cdr entry) :tool (alist-get 'tool_use_id request))))
      (roost-chat--set-state 'waiting)
      (roost-chat--present))))

(defun roost-chat--on-answer (tool note)
  "Show NOTE, how you answered the request about tool call TOOL.
The request closes if it is open here; otherwise NOTE goes under the
tool call, as after a reconnect."
  (if-let* ((entry (seq-find (lambda (entry) (equal (plist-get (cdr entry) :tool) tool))
                             roost-chat--requests)))
      (roost-chat--settle (car entry) note)
    (when-let* ((call (cdr (assoc tool roost-reader--tools))))
      (roost-chat--following
        (goto-char (nth 1 call))
        (forward-line 1)
        ;; Before the marks there, such as the next tool call's.
        (insert-before-markers (propertize (concat note "\n") 'face 'roost-chat-settled
                                           'line-prefix "  " 'wrap-prefix "  "))))))

(defun roost-chat--open (id plist)
  "Show request ID, whose PLIST's :draw inserts it and :keys answer it."
  (roost-chat--at-end
    (let ((start (point-marker)))
      (funcall (plist-get plist :draw))
      (setq roost-chat--requests
            (append roost-chat--requests
                    (list (cons id (append (list :start start :end (point-marker)) plist))))))))

(defun roost-chat--redraw (id)
  "Draw request ID again, after an answer to part of it."
  (when-let* ((plist (cdr (assoc id roost-chat--requests))))
    (let ((end (plist-get plist :end)))
      (roost-chat--following
        ;; The new text goes in before the old comes out, so marks on what
        ;; follows, such as a later tool call's, stay after it.
        (goto-char (plist-get plist :start))
        (funcall (plist-get plist :draw))
        (delete-region (point) end)
        (set-marker end (point))))))

(defun roost-chat--settle (id note)
  "Replace request ID with NOTE, saying how it was answered, and forget it."
  (when-let* ((entry (assoc id roost-chat--requests)))
    (let ((plist (cdr entry)))
      (roost-chat--following
        (goto-char (plist-get plist :start))
        (insert (propertize (concat note "\n") 'face 'roost-chat-settled
                            'line-prefix "  " 'wrap-prefix "  "))
        (delete-region (point) (plist-get plist :end))))
    (setq roost-chat--requests (delq entry roost-chat--requests))
    (when (and (null roost-chat--requests) (eq roost-chat--state 'waiting))
      (roost-chat--set-state 'working)
      (roost-chat--return-to-input))))

(defun roost-chat--draw-box (title body choices)
  "Insert a request: TITLE, then BODY's insertions, then CHOICES.
Each choice is (LABEL KEY FACE ACTION)."
  (insert "\n")
  (let ((start (point))
        (prefix (propertize "  " 'face 'roost-chat-request)))
    (insert "\n" (propertize title 'face 'roost-chat-request-title) "\n")
    (when body (funcall body))
    (when choices
      (insert "\n")
      (dolist (choice choices)
        (pcase-let ((`(,label ,key ,face ,action) choice))
          (insert-text-button label 'face face 'action (lambda (_) (funcall action))
                              'follow-link t 'mouse-face '(:underline t)
                              'help-echo (format "%s (%s)" label key))
          (insert "   ")))
      (insert (propertize (mapconcat #'cadr choices " · ") 'face 'roost-chat-key) "\n"))
    (insert "\n")
    (add-face-text-property start (point) 'roost-chat-request t)
    (add-text-properties start (point) (list 'line-prefix prefix 'wrap-prefix prefix))))

(defun roost-chat--file-name (input)
  "The file INPUT names, without its directory."
  (file-name-nondirectory (or (alist-get 'file_path input) "")))

(defun roost-chat--asks (tool input)
  "What Claude asks to do with TOOL and INPUT."
  (pcase tool
    ("Bash" "Allow Claude to run this command?")
    ("Write" (format "Allow Claude to %s %s?"
                     (if (file-exists-p (or (alist-get 'file_path input) "")) "overwrite" "create")
                     (roost-chat--file-name input)))
    ((or "Edit" "MultiEdit" "NotebookEdit")
     (format "Allow Claude to edit %s?" (roost-chat--file-name input)))
    ("WebFetch" (format "Allow Claude to fetch %s?"
                        (or (ignore-errors (url-host (url-generic-parse-url (alist-get 'url input))))
                            (alist-get 'url input))))
    ((pred (string-prefix-p "mcp__"))
     (pcase-let ((`(,_ ,server ,name) (split-string tool "__")))
       (format "Allow Claude to use %s from %s?" name server)))
    (_ (format "Allow Claude to use %s?" tool))))

(defun roost-chat--insert-details (tool input)
  "Insert what TOOL would do with INPUT."
  (pcase tool
    ("Bash"
     (when-let* ((description (alist-get 'description input)))
       (insert (propertize description 'face 'roost-reader-italic) "\n"))
     (roost-reader--insert-code (alist-get 'command input) "sh"))
    ((or "Edit" "MultiEdit") (roost-reader--insert-diff (roost-reader--clip (roost-reader--edit-diff input) 30)))
    ("Write" (roost-reader--insert-code (roost-reader--clip (alist-get 'content input) 20)
                                        (file-name-extension (or (alist-get 'file_path input) ""))))
    ("WebFetch" (insert (alist-get 'url input) "\n"))
    (_ (roost-reader--insert-code (roost-reader--clip (json-encode input) 12) "json"))))

(defun roost-chat--suggestion-label (suggestion)
  "A choice's label for the standing permission SUGGESTION."
  (let ((where (pcase (alist-get 'destination suggestion)
                 ("session" "this session")
                 ((or "localSettings" "projectSettings") "in this project")
                 ("userSettings" "everywhere")
                 (_ "from now on"))))
    (pcase (alist-get 'type suggestion)
      ("setMode" (pcase (alist-get 'mode suggestion)
                   ("acceptEdits" "Allow all edits this session")
                   (mode (format "Switch to %s" (roost-chat--mode-label mode)))))
      ("addRules" (let ((rule (car (alist-get 'rules suggestion))))
                    (format "Always allow %s %s"
                            (roost-reader--short (or (alist-get 'ruleContent rule)
                                                     (alist-get 'toolName rule) "this")
                                                 28)
                            where)))
      ("addDirectories" (format "Allow %s %s"
                                (abbreviate-file-name (car (alist-get 'directories suggestion)))
                                where))
      (_ "Always allow"))))

(defun roost-chat--permission (id request exact)
  "Ask whether Claude may use a tool, as REQUEST ID asks; EXACT is it to send back."
  (let* ((tool (alist-get 'tool_name request))
         (input (alist-get 'input request))
         (suggestion (car (alist-get 'permission_suggestions request)))
         (always (and suggestion (roost-chat--suggestion-label suggestion)))
         (allow (lambda () (roost-chat--allow id (alist-get 'input exact) nil "Allowed")))
         (allow-always (lambda ()
                         (when (equal (alist-get 'type suggestion) "setMode")
                           (setq roost-chat--mode (alist-get 'mode suggestion)))
                         (roost-chat--allow id (alist-get 'input exact)
                                            (alist-get 'permission_suggestions exact)
                                            (concat "Allowed. " always))))
         (deny (lambda () (roost-chat--deny id nil t "Declined")))
         (redirect (lambda ()
                     (let ((what (read-string "Tell Claude what to do instead: ")))
                       (roost-chat--deny id what nil (concat "Declined: " what)))))
         (choices (delq nil (list (list "Allow" "a" 'roost-chat-button-yes allow)
                                  (and always (list always "A" 'roost-chat-button allow-always))
                                  (list "Decline" "d" 'roost-chat-button-no deny)
                                  (list "Tell Claude instead…" "D" 'roost-chat-button redirect)))))
    (roost-chat--open id (list :keys (mapcar (lambda (choice) (cons (cadr choice) (nth 3 choice))) choices)
                               :draw (lambda ()
                                       (roost-chat--draw-box (roost-chat--asks tool input)
                                                             (lambda () (roost-chat--insert-details tool input))
                                                             choices))))))

(defun roost-chat--allow (id input permissions note)
  "Let Claude go ahead with request ID's INPUT.
Add the standing PERMISSIONS, if any, and settle the request with NOTE."
  (roost-chat--respond id `((behavior . "allow") (updatedInput . ,input)
                            ,@(when permissions `((updatedPermissions . ,permissions))))
                       note)
  (roost-chat--settle id note))

(defun roost-chat--deny (id reason stop note)
  "Decline request ID, telling Claude REASON; STOP ends Claude's turn.
Settle the request with NOTE."
  (roost-chat--respond id `((behavior . "deny")
                            (message . ,(if (string-empty-p (or reason ""))
                                            "The user declined this."
                                          (concat "The user declined this and said: " reason)))
                            ,@(when stop '((interrupt . t))))
                       note)
  (roost-chat--settle id note))

(defun roost-chat--ask (id request exact)
  "Show Claude's questions, REQUEST ID; EXACT is it to send back."
  (let* ((questions (alist-get 'questions (alist-get 'input request)))
         (answers (make-vector (length questions) nil))
         (picks (make-vector (length questions) nil))
         (current (lambda () (seq-position answers nil)))
         (finish
          (lambda ()
            (if (seq-position answers nil)
                (roost-chat--redraw id)
              (let ((table (make-hash-table :test #'equal)))
                (seq-do-indexed (lambda (question i)
                                  (puthash (alist-get 'question question) (aref answers i) table))
                                questions)
                (let ((note (mapconcat (lambda (answer) (concat "You answered: " answer)) answers "\n")))
                  (roost-chat--respond id `((behavior . "allow")
                                            (updatedInput . ((answers . ,table)
                                                             ,@(alist-get 'input exact))))
                                       note)
                  (roost-chat--settle id note))))))
         (choose
          (lambda (n)
            (when-let* ((i (funcall current))
                        (option (nth (1- n) (alist-get 'options (nth i questions)))))
              (let ((label (alist-get 'label option)))
                (if (alist-get 'multiSelect (nth i questions))
                    (progn (aset picks i (if (member label (aref picks i))
                                             (delete label (aref picks i))
                                           (append (aref picks i) (list label))))
                           (roost-chat--redraw id))
                  (aset answers i label)
                  (funcall finish))))))
         (other (lambda ()
                  (when-let* ((i (funcall current)))
                    (aset answers i (read-string (concat (alist-get 'question (nth i questions)) " ")))
                    (funcall finish))))
         (done (lambda ()
                 (when-let* ((i (funcall current)))
                   (when (aref picks i)
                     (aset answers i (string-join (aref picks i) ", "))
                     (funcall finish)))))
         (skip (lambda () (roost-chat--deny id nil t "You didn't answer; Claude stopped")))
         (keys (append (mapcar (lambda (n) (cons (number-to-string n) (lambda () (funcall choose n))))
                               (number-sequence 1 9))
                       `(("o" . ,other) ("x" . ,done) ("d" . ,skip)))))
    (roost-chat--open
     id (list :keys keys
              :draw (lambda ()
                      (roost-chat--draw-box
                       "Claude asks"
                       (lambda () (roost-chat--insert-questions questions answers picks (funcall current)
                                                                choose other))
                       (delq nil (list (and (funcall current)
                                            (alist-get 'multiSelect (nth (funcall current) questions))
                                            (list "Done" "x" 'roost-chat-button-yes done))
                                       (list "Skip" "d" 'roost-chat-button-no skip)))))))))

(defun roost-chat--insert-questions (questions answers picks current choose other)
  "Insert QUESTIONS, with their ANSWERS so far and multiple-choice PICKS.
The CURRENT question's options CHOOSE an answer, or OTHER asks for one."
  (seq-do-indexed
   (lambda (question i)
     (insert "\n" (propertize (upcase (or (alist-get 'header question) "")) 'face 'roost-chat-key) "\n"
             (propertize (alist-get 'question question) 'face 'roost-reader-bold) "\n")
     (cond
      ((aref answers i)
       (insert (propertize (concat "→ " (aref answers i)) 'face 'roost-reader-italic) "\n"))
      ((eq i current)
       (let ((multi (alist-get 'multiSelect question)))
         (seq-do-indexed
          (lambda (option n)
            (let ((label (alist-get 'label option)))
              (insert (propertize (format " %d " (1+ n)) 'face 'roost-chat-button) "  ")
              (insert-text-button (concat (when multi (if (member label (aref picks i)) "☑ " "☐ ")) label)
                                  'face 'roost-reader-bold 'follow-link t 'mouse-face '(:underline t)
                                  'action (lambda (_) (funcall choose (1+ n))))
              (when-let* ((description (alist-get 'description option)))
                (insert (propertize (concat "  " description) 'face 'roost-reader-note)))
              (insert "\n")))
          (alist-get 'options question))
         (insert (propertize " o " 'face 'roost-chat-button) "  ")
         (insert-text-button "Something else…" 'face 'roost-reader-italic 'follow-link t
                             'mouse-face '(:underline t) 'action (lambda (_) (funcall other)))
         (insert "\n")))
      (t (insert (propertize "Next" 'face 'roost-reader-note) "\n"))))
   questions))

(defun roost-chat--plan (id request exact)
  "Show Claude's plan, REQUEST ID, to approve; EXACT is it to send back."
  (let* ((plan (alist-get 'plan (alist-get 'input request)))
         (input (alist-get 'input exact))
         (approve (lambda (mode note)
                    (lambda ()
                      (setq roost-chat--mode mode)
                      (roost-chat--allow id input
                                         (vector `((type . "setMode") (mode . ,mode)
                                                   (destination . "session")))
                                         note))))
         (revise (lambda ()
                   (let ((what (read-string "What should Claude change? ")))
                     (roost-chat--deny id (if (string-empty-p what) "Keep planning." what) nil
                                       "You asked Claude to keep planning"))))
         (choices (list (list "Approve; accept edits" "A" 'roost-chat-button-yes
                              (funcall approve "acceptEdits" "Plan approved; Claude edits without asking"))
                        (list "Approve; ask before edits" "a" 'roost-chat-button
                              (funcall approve "default" "Plan approved; Claude asks before editing"))
                        (list "Keep planning…" "d" 'roost-chat-button-no revise))))
    (roost-chat--open id (list :keys (mapcar (lambda (choice) (cons (cadr choice) (nth 3 choice))) choices)
                               :draw (lambda ()
                                       (roost-chat--draw-box "Claude's plan"
                                                             (lambda () (insert "\n")
                                                               (roost-reader--insert-markdown (string-trim plan)))
                                                             choices))))))

(defun roost-chat-answer ()
  "Answer the oldest request waiting for you with the key you pressed."
  (interactive)
  (let* ((key (key-description (this-command-keys)))
         (plist (cdar roost-chat--requests))
         (action (cdr (assoc key (plist-get plist :keys)))))
    (cond (action (funcall action))
          (plist (message "%s doesn't answer this request" key))
          (t (message "Nothing is waiting for an answer")))))

(defun roost-chat--present ()
  "Bring a new request to your attention, as a dialog takes focus."
  (let ((window (get-buffer-window (current-buffer) t)))
    ;; The request is at the end; show it even if you had scrolled away.
    (when window
      (set-window-point window (point-max))
      (with-selected-window window (recenter -1)))
    (when (and window (buffer-live-p roost-chat--input)
               (eq (window-buffer (selected-window)) roost-chat--input)
               (zerop (buffer-size roost-chat--input)))
      (select-window window)))
  (message "Claude is waiting for your answer"))

(defun roost-chat--return-to-input ()
  "Go back to the field once nothing waits for an answer."
  (let ((window (and (buffer-live-p roost-chat--input) (get-buffer-window roost-chat--input))))
    (when (and window (eq (window-buffer (selected-window)) (current-buffer)))
      (select-window window))))

;;;; Commands

(defun roost-chat--conversation-buffer ()
  "The conversation the current command is about."
  (let ((buffer (if (mouse-event-p last-input-event)
                    (window-buffer (posn-window (event-start last-input-event)))
                  (current-buffer))))
    (with-current-buffer buffer
      (cond ((derived-mode-p 'roost-chat-mode) buffer)
            ((buffer-live-p roost-chat--conversation) roost-chat--conversation)
            (t (user-error "Not in a conversation with Claude"))))))

(defun roost-chat-send ()
  "Send what you wrote to Claude."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (conversation (roost-chat--conversation-buffer)))
    (if (string-empty-p text)
        (message "Write something first")
      (with-current-buffer conversation (roost-chat--submit text))
      (erase-buffer))))

(defun roost-chat--submit (text)
  "Send TEXT to Claude, as from the field."
  (unless (process-live-p roost-chat--process)
    (user-error (if roost-chat--attach
                    "Not connected to Claude; g in the conversation connects again"
                  "Claude Code isn't running; g in the conversation starts it again")))
  ;; Claude repeats a prompt back as it takes it, but not a command.
  (when (string-prefix-p "/" text)
    (roost-chat--at-end (roost-reader--insert-prompt text)))
  (roost-chat--send `((type . "user") (message . ((role . "user") (content . ,text)))
                      (parent_tool_use_id . :null) (session_id . "default")))
  (roost-chat--set-state 'working))

(defun roost-chat-interrupt ()
  "Stop Claude, as Esc does in Claude Code."
  (interactive)
  (with-current-buffer (roost-chat--conversation-buffer)
    (if (not (memq roost-chat--state '(working waiting)))
        (message "Claude isn't working")
      (dolist (entry roost-chat--requests)
        (roost-chat--deny (car entry) nil t "Declined"))
      (roost-chat--control '((subtype . "interrupt"))))))

(defconst roost-chat--mode-cycle '("default" "acceptEdits" "plan")
  "The permission modes Shift-Tab steps through, as in Claude Code.")

(defun roost-chat--mode-label (&optional mode)
  "MODE, or the conversation's mode, in words."
  (pcase (or mode roost-chat--mode)
    ("default" "Ask before edits")
    ("acceptEdits" "Accept edits")
    ("plan" "Plan mode")
    ("auto" "Auto mode")
    ("bypassPermissions" "Bypass permissions")
    ("dontAsk" "Don't ask")
    (other other)))

(defun roost-chat--pick (prompt items)
  "Choose among ITEMS, (LABEL . VALUE), with PROMPT.
A click shows a menu where you clicked; a key reads the choice."
  (if (mouse-event-p last-input-event)
      (x-popup-menu last-input-event (list prompt (cons prompt items)))
    (cdr (assoc (completing-read (concat prompt ": ") items nil t) items))))

(defun roost-chat-cycle-mode ()
  "Step to the next permission mode, as Shift-Tab does in Claude Code."
  (interactive)
  (with-current-buffer (roost-chat--conversation-buffer)
    (let* ((next (or (cadr (member roost-chat--mode roost-chat--mode-cycle)) "default"))
           (buffer (current-buffer)))
      (roost-chat--control `((subtype . "set_permission_mode") (mode . ,next))
                           (lambda (_)
                             (with-current-buffer buffer
                               (setq roost-chat--mode next)
                               (roost-chat--refresh-controls)))))))

(defun roost-chat--model-label ()
  "The model's name."
  (or (seq-some (lambda (model)
                  (and (equal (alist-get 'resolvedModel model) roost-chat--model)
                       (not (equal (alist-get 'value model) "default"))
                       (alist-get 'displayName model)))
                roost-chat--models)
      roost-chat--model
      "Model"))

(defun roost-chat-choose-model ()
  "Choose the model Claude uses from now on."
  (interactive)
  (with-current-buffer (roost-chat--conversation-buffer)
    (let* ((buffer (current-buffer))
           (models (seq-remove (lambda (model) (equal (alist-get 'value model) "default"))
                               roost-chat--models))
           (value (roost-chat--pick "Model" (mapcar (lambda (model)
                                                      (cons (format "%s — %s" (alist-get 'displayName model)
                                                                    (alist-get 'description model))
                                                            (alist-get 'value model)))
                                                    models))))
      (when value
        (roost-chat--control `((subtype . "set_model") (model . ,value))
                             (lambda (_)
                               (with-current-buffer buffer
                                 (setq roost-chat--model
                                       (alist-get 'resolvedModel
                                                  (seq-find (lambda (model) (equal (alist-get 'value model) value))
                                                            models)))
                                 (roost-chat--refresh-controls))))))))

(defun roost-chat-focus-input ()
  "Go to the field you write in."
  (interactive)
  (when-let* ((window (and (buffer-live-p roost-chat--input) (get-buffer-window roost-chat--input))))
    (select-window window)))

(defun roost-chat-restart ()
  "Start Claude Code again on this conversation, if it has stopped."
  (interactive)
  (cond ((process-live-p roost-chat--process) (message "Claude Code is running"))
        (roost-chat--attach (roost-chat--reset) (roost-chat--start nil))
        (t (roost-chat--start roost-chat--session))))

(defun roost-chat--reset ()
  "Empty the conversation, to draw it again from its agent."
  (let ((inhibit-read-only t))
    (when (fboundp 'get-buffer-xwidgets)
      (mapc #'kill-xwidget (get-buffer-xwidgets (current-buffer))))
    (erase-buffer)
    (setq roost-reader--tools nil roost-reader--turns 0 roost-chat--requests nil
          roost-chat--live nil roost-chat--live-text "" roost-chat--seen (make-hash-table :test #'equal))
    (roost-chat--insert-title)))

(defun roost-chat--insert-title ()
  "Insert the conversation's name, and the line about it, at its top."
  (roost-chat--at-end
    (insert (propertize (car roost-chat--title) 'face 'roost-reader-h2) "\n"
            (propertize (cdr roost-chat--title) 'face 'roost-reader-note) "\n")))

;;;; The field you write in

(defun roost-chat--control-button (label command help)
  "LABEL in the controls, running COMMAND when clicked, explained by HELP."
  (propertize label 'face 'roost-chat-control 'mouse-face 'mode-line-highlight 'help-echo help
              'local-map (let ((map (make-sparse-keymap)))
                           (define-key map [mode-line mouse-1] command)
                           map)))

(defun roost-chat--controls ()
  "The controls under the field."
  (when (buffer-live-p roost-chat--conversation)
    (with-current-buffer roost-chat--conversation
      (let ((separator (propertize "   ·   " 'face 'roost-chat-control)))
        (concat
         "    "
         (propertize (concat "⌂ " (or roost-chat--where
                                      (file-name-nondirectory (directory-file-name roost-chat--directory))))
                     'face 'roost-chat-control)
         separator
         (roost-chat--control-button (concat "⊕ " (roost-chat--mode-label)) #'roost-chat-cycle-mode
                                     "Click, or Shift-Tab: change when Claude asks")
         separator
         (roost-chat--control-button (roost-chat--model-label) #'roost-chat-choose-model
                                     "Click: choose the model")
         separator
         (propertize (pcase roost-chat--state
                       ('starting "Starting…") ('ready "Ready") ('working "Working…")
                       ('waiting "Waiting for you") ('stopped "Stopped")
                       ('detached "Not connected"))
                     'face 'roost-chat-control)
         (propertize "        ↵ send  ·  C-j new line  ·  C-c C-k stop" 'face 'roost-chat-control))))))

(defun roost-chat--refresh-controls ()
  "Redraw the controls under the field."
  (when (buffer-live-p roost-chat--input)
    (with-current-buffer roost-chat--input (force-mode-line-update))))

(defun roost-chat--complete-command ()
  "Complete a slash command at the start of the field."
  (when (save-excursion (skip-chars-backward "^ \t\n") (and (bobp) (eq (char-after) ?/)))
    (let ((commands (and (buffer-live-p roost-chat--conversation)
                         (buffer-local-value 'roost-chat--commands roost-chat--conversation))))
      (list (1+ (point-min)) (point) (mapcar #'car commands)
            :annotation-function (lambda (name)
                                   (concat "  " (roost-reader--short (cdr (assoc name commands)) 60)))
            :exclusive 'no))))

(defvar-local roost-chat--placeholder nil "Overlay saying what the empty field is for.")

(defun roost-chat--show-placeholder (&rest _)
  "Say what the field is for while it is empty."
  (unless (overlayp roost-chat--placeholder)
    (remove-overlays (point-min) (point-max) 'roost-chat-placeholder t)
    (setq roost-chat--placeholder (make-overlay (point-min) (point-min)))
    (overlay-put roost-chat--placeholder 'roost-chat-placeholder t))
  (overlay-put roost-chat--placeholder 'before-string
               (and (zerop (buffer-size))
                    (concat (propertize " " 'cursor t)
                            (propertize "Write to Claude…   / for commands" 'face 'shadow)))))

(defvar-keymap roost-chat-input-mode-map
  "RET" #'roost-chat-send
  "C-c C-c" #'roost-chat-send
  "C-j" #'newline
  "S-<return>" #'newline
  "C-c C-k" #'roost-chat-interrupt
  "<backtab>" #'roost-chat-cycle-mode
  "TAB" #'completion-at-point)

(define-derived-mode roost-chat-input-mode text-mode "Claude input"
  "The field where you write to Claude.
\\{roost-chat-input-mode-map}"
  (buffer-face-set 'roost-chat-input)
  (let ((background (face-background 'roost-chat-input nil t)))
    (dolist (face '(mode-line mode-line-active mode-line-inactive))
      (face-remap-add-relative face `(:background ,background :box nil :overline nil :underline nil)))
    (face-remap-add-relative 'fringe `(:background ,background)))
  (setq-local line-spacing 0.25
              cursor-type 'bar
              header-line-format nil
              tab-line-format nil
              mode-line-format '(:eval (roost-chat--controls)))
  (visual-line-mode 1)
  (add-hook 'after-change-major-mode-hook
            (lambda () (when (bound-and-true-p display-line-numbers-mode) (display-line-numbers-mode -1)))
            90 t)
  (add-hook 'completion-at-point-functions #'roost-chat--complete-command nil t)
  (add-hook 'after-change-functions #'roost-chat--show-placeholder nil t)
  (add-hook 'window-size-change-functions #'roost-reader--fit-column nil t)
  (roost-chat--show-placeholder))

;;;; Starting

(defvar-keymap roost-chat-mode-map
  :parent roost-reader-mode-map
  "i" #'roost-chat-focus-input
  "a" #'roost-chat-answer "A" #'roost-chat-answer
  "d" #'roost-chat-answer "D" #'roost-chat-answer
  "o" #'roost-chat-answer "x" #'roost-chat-answer
  "1" #'roost-chat-answer "2" #'roost-chat-answer "3" #'roost-chat-answer
  "4" #'roost-chat-answer "5" #'roost-chat-answer "6" #'roost-chat-answer
  "7" #'roost-chat-answer "8" #'roost-chat-answer "9" #'roost-chat-answer
  "C-c C-k" #'roost-chat-interrupt
  "<backtab>" #'roost-chat-cycle-mode
  "f" #'ignore
  "g" #'roost-chat-restart)

(define-derived-mode roost-chat-mode roost-reader-mode "Claude"
  "A conversation with Claude Code, typeset.
\\{roost-chat-mode-map}"
  (setq-local mode-line-format nil
              header-line-format nil
              cursor-in-non-selected-windows nil
              scroll-conservatively 101)
  (add-hook 'kill-buffer-hook #'roost-chat--teardown nil t))

(defun roost-chat--teardown ()
  "Stop Claude Code and close the field, as the conversation goes."
  (dolist (timer (list roost-chat--ticker roost-chat--live-timer))
    (when (timerp timer) (cancel-timer timer)))
  (when (process-live-p roost-chat--process) (delete-process roost-chat--process))
  (when (buffer-live-p roost-chat--input) (kill-buffer roost-chat--input)))

(defun roost-chat--program ()
  "Claude Code's executable."
  (or (executable-find roost-chat-program)
      (let ((local (expand-file-name "~/.local/bin/claude")))
        (and (file-executable-p local) local))
      (user-error "Can't find %s" roost-chat-program)))

(defun roost-chat--command (resume)
  "The command running Claude Code, resuming session RESUME if given."
  (append (list (roost-chat--program)
                "--input-format" "stream-json" "--output-format" "stream-json" "--verbose"
                "--include-partial-messages" "--replay-user-messages"
                "--permission-prompt-tool" "stdio")
          (when roost-chat-model (list "--model" roost-chat-model))
          (when resume (list "--resume" resume))
          (when (and roost-chat-diagrams (file-exists-p roost-chat--diagram-server))
            (list "--mcp-config"
                  (json-serialize `((mcpServers . ((roost . ((command . "python3")
                                                             (args . [,roost-chat--diagram-server])))))))
                  "--allowedTools" "mcp__roost__show_diagram"))))

(defun roost-chat--start (resume)
  "Start Claude Code for this conversation, resuming session RESUME if given."
  (let* ((buffer (current-buffer))
         (default-directory (if roost-chat--attach temporary-file-directory roost-chat--directory))
         (process-environment (cons "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true"
                                    process-environment)))
    (setq roost-chat--partial ""
          roost-chat--process
          (make-process :name "roost-chat"
                        :command (if roost-chat--attach
                                     (funcall roost-chat--attach)
                                   (roost-chat--command resume))
                        :connection-type 'pipe :noquery t :coding 'utf-8-unix
                        :stderr (get-buffer-create (concat " *stderr " (buffer-name) "*"))
                        :filter (lambda (_ output) (roost-chat--filter buffer output))
                        :sentinel (lambda (_ _event)
                                    (when (buffer-live-p buffer)
                                      (with-current-buffer buffer
                                        (dolist (entry roost-chat--requests)
                                          (roost-chat--settle (car entry) "Not answered here"))
                                        ;; A task's agent goes on without us.
                                        (roost-chat--set-state (if roost-chat--attach 'detached 'stopped)))))))
    (roost-chat--set-state 'starting)
    (roost-chat--control '((subtype . "initialize") (hooks . :null))
                         (lambda (response)
                           (with-current-buffer buffer (roost-chat--initialized response))))))

(defun roost-chat--project-logs (directory)
  "Claude Code's session logs for DIRECTORY, newest first."
  (let ((logs (expand-file-name (replace-regexp-in-string
                                 "[^a-zA-Z0-9]" "-" (directory-file-name (file-truename directory)))
                                "~/.claude/projects/")))
    (and (file-directory-p logs)
         (sort (directory-files logs t "\\.jsonl\\'") #'file-newer-than-file-p))))

(defun roost-chat--log-title (file)
  "The first thing you wrote in the session logged in FILE."
  (with-temp-buffer
    (insert-file-contents file nil 0 65536)
    (catch 'title
      (dolist (line (split-string (buffer-string) "\n" t))
        (let* ((entry (ignore-errors (roost-chat--parse line)))
               (content (alist-get 'content (alist-get 'message entry))))
          (when (and (equal (alist-get 'type entry) "user") (not (alist-get 'isMeta entry)))
            (let ((text (if (stringp content) content
                          (seq-some (lambda (block) (alist-get 'text block)) content))))
              (when (roost-reader--user-text-p text)
                (throw 'title (roost-reader--short text 70)))))))
      "(untitled)")))

;;;###autoload
(defun roost-chat (directory &optional log)
  "Talk to Claude Code working in DIRECTORY.
With a prefix argument, choose a past session to go on with; LOG is its file."
  (interactive
   (let ((directory (read-directory-name "Claude works in: " nil nil t)))
     (list directory
           (when current-prefix-arg
             (let* ((logs (or (roost-chat--project-logs directory)
                              (user-error "No sessions in %s yet" directory)))
                    (items (mapcar (lambda (file)
                                     (cons (format "%s  %s"
                                                   (format-time-string "%b %e %H:%M"
                                                                       (file-attribute-modification-time
                                                                        (file-attributes file)))
                                                   (roost-chat--log-title file))
                                           file))
                                   (seq-take logs 30))))
               (cdr (assoc (completing-read "Go on with: " items nil t) items)))))))
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (roost-chat--display
     (roost-chat--create (file-name-nondirectory (directory-file-name directory))
                         (abbreviate-file-name directory) directory nil log))))

;;;###autoload
(defun roost-chat-task (task)
  "Show Roost TASK's conversation, attached to its agent on the task's host."
  (roost-chat--display (roost-chat--task-buffer task)))

;;;###autoload
(defun roost-chat-send-to-task (task text)
  "Send TEXT to Roost TASK's Claude, through its conversation, shown or not."
  (with-current-buffer (roost-chat--task-buffer task)
    (roost-chat--submit text)))

(defun roost-chat--task-buffer (task)
  "Roost TASK's conversation, attached to its agent on the task's host."
  (let* ((key (roost--key task))
         (conversation
          (or (seq-find (lambda (buffer) (equal (buffer-local-value 'roost-chat--task-key buffer) key))
                        (buffer-list))
              (let ((buffer (roost-chat--create
                             (roost--field task 'name)
                             (format "%s · %s" (roost--host-label (roost--field task 'host))
                                     (roost--field task 'branch))
                             (roost--remote-directory task)
                             (lambda () (roost--attach-command task)))))
                (with-current-buffer buffer
                  (setq roost-chat--task-key key
                        roost-chat--where (roost--host-label (roost--field task 'host))))
                buffer))))
    (with-current-buffer conversation
      (unless (process-live-p roost-chat--process) (roost-chat-restart)))
    conversation))

(defun roost-chat--create (name line directory &optional attach log)
  "Start a conversation called NAME, about which LINE says more.
Claude works in DIRECTORY.  ATTACH, for a Roost task, returns the argv
attaching to its agent; otherwise Claude Code runs here, going on with
the session in LOG if given.  Return the conversation's buffer."
  (let ((conversation (generate-new-buffer (format "*Claude: %s*" name)))
        (input (generate-new-buffer (format " *Claude input: %s*" name))))
    (with-current-buffer input
      (roost-chat-input-mode)
      (setq roost-chat--conversation conversation))
    (with-current-buffer conversation
      (roost-chat-mode)
      (setq roost-chat--directory directory
            roost-chat--input input
            roost-chat--attach attach
            roost-chat--title (cons name line)
            roost-chat--seen (make-hash-table :test #'equal))
      (roost-chat--insert-title)
      (when log
        ;; The session so far, from its log, as the reader draws it.
        (setq roost-reader--file log roost-reader--offset 0)
        (roost-chat--at-end (mapc #'roost-reader--insert-entry (roost-reader--read-new))))
      (roost-chat--start (and log (file-name-base log))))
    conversation))

(defun roost-chat--display (conversation)
  "Show CONVERSATION in the selected window, its field below, and go to the field."
  (let ((input (buffer-local-value 'roost-chat--input conversation)))
    (pop-to-buffer-same-window conversation)
    (let* ((window (selected-window))
           (below (window-in-direction 'below window))
           (field (or (get-buffer-window input)
                      ;; The field of the conversation this window showed before.
                      (and below (with-current-buffer (window-buffer below)
                                   (derived-mode-p 'roost-chat-input-mode))
                           below)
                      (split-window window -6 'below))))
      (set-window-dedicated-p field nil)
      (set-window-buffer field input)
      (set-window-dedicated-p field t)
      (window-preserve-size field nil t)
      (roost-reader--fit-column window)
      (roost-reader--fit-column field)
      (set-window-point window (with-current-buffer conversation (point-max)))
      (add-hook 'window-buffer-change-functions #'roost-chat--tidy-fields)
      (select-window field))))

(defun roost-chat--tidy-fields (frame)
  "Close the fields in FRAME whose conversation no longer shows above them."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'roost-chat-input-mode)
        (let ((above (window-in-direction 'above window)))
          (unless (and above (eq (window-buffer above) roost-chat--conversation))
            (ignore-errors (delete-window window))))))))

(provide 'roost-chat)
;;; roost-chat.el ends here
