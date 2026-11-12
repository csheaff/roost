;;; roost-webkit-read.el --- Read a Claude conversation in WebKit  -*- lexical-binding: t; -*-

;;; Commentary:

;; A throwaway prototype, not part of Roost.  `roost-webkit-read' shows the
;; Claude Code conversation of the current directory as a typeset page in an
;; xwidget WebKit buffer: each turn is your prompt and the agent's last
;; reply, the steps between folded, screenshots as thumbnails.  `g' reads
;; the log again, `q' goes back to where you were.
;;
;; It needs an Emacs built with xwidgets, a GUI frame, and python3.  It reads
;; logs on this machine only.

;;; Code:

(require 'xwidget)

(defconst roost-webkit-read--script
  (expand-file-name "transcript_html.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The program that turns a session log into a page.")

(defvar-local roost-webkit-read--log nil
  "The session log this buffer shows.")

(defun roost-webkit-read--folder (directory)
  "The folder of Claude's session logs for DIRECTORY, as Claude names it."
  (expand-file-name
   (replace-regexp-in-string "[^[:ascii:]]\\|[^A-Za-z0-9]" "-"
                             (directory-file-name (file-truename directory)))
   "~/.claude/projects/"))

(defun roost-webkit-read--newest (directory)
  "The newest session log of DIRECTORY, or nil."
  (let ((folder (roost-webkit-read--folder directory)))
    (when (file-directory-p folder)
      (car (sort (directory-files folder t "\\.jsonl\\'")
                 (lambda (a b)
                   (time-less-p (file-attribute-modification-time (file-attributes b))
                                (file-attribute-modification-time (file-attributes a)))))))))

(defun roost-webkit-read--page (log)
  "Write LOG as a page and return the page's file name."
  (let ((page (expand-file-name (concat "roost-read-" (file-name-base log) ".html")
                                temporary-file-directory)))
    (with-temp-buffer
      (unless (eq 0 (call-process "python3" nil t nil "-I"
                                  roost-webkit-read--script log page))
        (error "Could not read %s: %s" log (string-trim (buffer-string)))))
    page))

(defvar roost-webkit-read-send-function
  (lambda (kind text) (message "Widget %s: %s" kind text))
  "What to do when a widget in the page asks for something.
Called with KIND, \"prompt\" or \"link\", and its TEXT.  The prototype
only says what was asked; Roost would send a prompt to the task.")

(defvar roost-webkit-read-asked nil
  "What widgets have asked for, newest first, as (KIND . TEXT).")

(defvar-local roost-webkit-read--timer nil
  "The timer that collects what this buffer's widgets ask for.")

(defun roost-webkit-read--collected (reply)
  "Act on REPLY, JSON of what a page's widgets asked for and its folder."
  (when-let* (((stringp reply))
              (data (ignore-errors (json-parse-string reply :object-type 'alist
                                                      :array-type 'list
                                                      :null-object nil))))
    (dolist (item (alist-get 'items data))
      (let ((kind (alist-get 'kind item)) (text (alist-get 'text item))
            (dir (alist-get 'dir data)))
        (push (cons kind text) roost-webkit-read-asked)
        (if (and dir (equal kind "prompt"))
            (roost-webkit-show--send dir text)
          (funcall roost-webkit-read-send-function kind text))))))

(defun roost-webkit-read--collect (buffer)
  "Take what the widgets in BUFFER's page have asked for since last time.
The callback is a named function on purpose: on macOS Emacs keeps no
reference to a callback while WebKit runs the script, so a closure made
here can be collected before the reply comes, and Emacs crashes on it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((session (xwidget-webkit-current-session)))
        (xwidget-webkit-execute-script
         session (concat "JSON.stringify({dir: window.roostDir || null,"
                         " items: (window.roostOutbox || []).splice(0)})")
         #'roost-webkit-read--collected)))))

(defun roost-webkit-read--stop ()
  "Stop collecting from this buffer's page."
  (when (timerp roost-webkit-read--timer)
    (cancel-timer roost-webkit-read--timer)))

(defvar-keymap roost-webkit-read-mode-map
  "q" #'quit-window
  "g" #'roost-webkit-read-again)

(define-minor-mode roost-webkit-read-mode
  "Keys for a conversation shown in WebKit: \\`g' reads it again, \\`q' leaves."
  :lighter " Read")

(defun roost-webkit-read-again ()
  "Read the session log again and show the newest turn."
  (interactive)
  (roost-webkit-read--page roost-webkit-read--log)
  (xwidget-webkit-reload))

(defun roost-webkit-read (log)
  "Show the Claude conversation in session LOG as a page to read.
LOG is the newest conversation of the current directory, or with a
prefix argument, or when there is none, one you pick."
  (interactive
   (list (or (and (not current-prefix-arg)
                  (roost-webkit-read--newest default-directory))
             (read-file-name "Session log: " "~/.claude/projects/" nil t))))
  (unless (featurep 'xwidget-internal)
    (user-error "This Emacs was built without xwidgets"))
  (unless (display-graphic-p)
    (user-error "A WebKit view needs a graphical frame"))
  (let ((page (roost-webkit-read--page log)))
    (xwidget-webkit-browse-url (concat "file://" page) t)
    (with-current-buffer (xwidget-buffer (xwidget-webkit-last-session))
      (setq roost-webkit-read--log log)
      (roost-webkit-read-mode 1)
      (setq roost-webkit-read--timer
            (run-at-time 0.5 0.5 #'roost-webkit-read--collect (current-buffer)))
      (add-hook 'kill-buffer-hook #'roost-webkit-read--stop nil t))))

;; Pages a live agent shows ------------------------------------------------

(defvar-local roost-webkit-show--dir nil
  "The folder of pages this buffer follows.")

(defvar-local roost-webkit-show--seen nil
  "An alist of each page file this buffer has drawn and its size and time.")

(defun roost-webkit-show--send (dir text)
  "Leave TEXT in DIR's inbox, for the agent's extension to send as a prompt."
  (let ((inbox (expand-file-name "inbox" dir))
        (coding-system-for-write 'utf-8))
    (make-directory inbox t)
    (write-region text nil (expand-file-name (format-time-string "%s%6N.part" ) inbox)
                  nil 'silent)
    (dolist (part (directory-files inbox t "\\.part\\'"))
      (rename-file part (concat (file-name-sans-extension part) ".txt") t))
    (message "Sent to the agent: %s" text)))

(defun roost-webkit-show--follow (buffer)
  "Draw in BUFFER's page each page file that is new or has changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((session (xwidget-webkit-current-session)))
        (dolist (file (directory-files roost-webkit-show--dir t "\\`[0-9]+\\.json\\'"))
          (let* ((attributes (file-attributes file))
                 (stamp (list (file-attribute-size attributes)
                              (file-attribute-modification-time attributes))))
            (unless (equal stamp (alist-get file roost-webkit-show--seen nil nil #'equal))
              (setf (alist-get file roost-webkit-show--seen nil nil #'equal) stamp)
              (xwidget-webkit-execute-script
               session
               (format "window.roostDir = %s; roostShow(%s, %s)"
                       (json-encode roost-webkit-show--dir)
                       (json-encode (file-name-base file))
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))))))
        (roost-webkit-read--collect buffer)))))

(defun roost-webkit-show (dir)
  "Follow the pages an agent shows in folder DIR, in a WebKit view.
The agent is Pi run with the extension in pi-show beside this file and
ROOST_SHOW_DIR set to DIR.  What you click in a page that asks the agent
something is sent to it as your next prompt."
  (interactive "DFolder of shown pages: ")
  (unless (featurep 'xwidget-internal)
    (user-error "This Emacs was built without xwidgets"))
  (let ((page (expand-file-name "roost-show.html" temporary-file-directory)))
    (with-temp-buffer
      (unless (eq 0 (call-process "python3" nil t nil "-I"
                                  roost-webkit-read--script "--live" page))
        (error "Could not make the page: %s" (string-trim (buffer-string)))))
    (xwidget-webkit-browse-url (concat "file://" page) t)
    (with-current-buffer (xwidget-buffer (xwidget-webkit-last-session))
      (setq roost-webkit-show--dir (directory-file-name (expand-file-name dir)))
      (roost-webkit-read-mode 1)
      (setq roost-webkit-read--timer
            (run-at-time 1 0.25 #'roost-webkit-show--follow (current-buffer)))
      (add-hook 'kill-buffer-hook #'roost-webkit-read--stop nil t))))

(provide 'roost-webkit-read)
;;; roost-webkit-read.el ends here
