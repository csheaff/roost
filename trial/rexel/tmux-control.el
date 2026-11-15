;;; tmux-control.el --- Trial: what Roost calls of tmux-control, on rexel  -*- lexical-binding: t; -*-

;; Version: 99.0
;; Package-Requires: ((emacs "30.1") (ghostel "0.65.0") (rexel "0.5.0"))
;; Written against rexel 0.5.0 at 02d495d (2026-11-15) and Rex
;; 0.1.0-preview.19.

;;; Commentary:

;; A trial, not for release.  Roost reaches its terminals through about
;; twenty functions, two hooks and one mode of tmux-control.  This file
;; gives them the same names on top of rexel, so that Roost shows tasks
;; its helper keeps in a Rex server, with this directory on the load
;; path in place of tmux-control's:
;;
;;   emacs -L trial/rexel -L <ghostel>/lisp -L <rexel>/lisp ...
;;
;; The helper keeps a task in Rex when its socket is named "rex:ADDRESS",
;; ADDRESS being the server's as `rex -S' takes it: set
;; `roost-socket-name' to that.  A task is a Rex session of one terminal
;; block, labelled as its tmux session would be named.
;;
;; rexel 0.5.0 has public functions to look a block buffer up, and none
;; to connect, attach or ask the server anything.  Each private name
;; this file calls is marked NEEDS, with what a public one would have to
;; do.  Only a server on this machine, at a Unix socket, for now.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ghostel)
(require 'rexel)

(defgroup tmux-control nil
  "Trial stand-in for tmux-control on rexel."
  :group 'terminals)

(defconst tmux-control-version "99.0"
  "A version above any Roost asks for.")

(defcustom tmux-control-default-socket-name "main"
  "Default socket name.  For Rex, \"rex:\" and the server's address."
  :type 'string)

(defvar tmux-control-ssh-options nil "Unused here.")
(defvar tmux-control-remote-tmux-socket-setup ":"
  "Unused here: Rex has no socket directory to set up.")
(defvar tmux-control-session-activity nil "Unused here.")
(defvar tmux-control-switch-session-functions nil "Never run here.")

(defvar tmux-control-window-buffer-functions nil
  "Functions called with each block buffer rexel makes for a session of ours.")

;; Roost asks `derived-mode-p' of `tmux-control-mode'.  A block buffer is
;; a Ghostel terminal with `rexel-block-mode', a minor mode, on.
(derived-mode-add-parents 'ghostel-mode '(tmux-control-mode))

(define-derived-mode tmux-control-connecting-mode special-mode "Connecting"
  "For the buffer a window shows until its Rex session's block arrives.")
(derived-mode-add-parents 'tmux-control-connecting-mode '(tmux-control-mode))

;; Roost kills terminal buffers of tasks that ended, and rexel would then
;; close the block, asking first if a program runs in it.  The helper
;; ends a task's blocks; Emacs only stops looking.  And a session whose
;; last block closed is the helper's to end.
(setq rexel-kill-buffer-action 'keep
      rexel-destroy-empty-sessions nil)


;;; Which session a buffer belongs to

(defvar-local tmux-control--place nil
  "The (HOST SOCKET SESSION) of this block or stand-in buffer.
rexel says a block buffer's session label and host only while its
connection lasts, and never its server's address.")

(defvar tmux-control--places (make-hash-table :test #'equal)
  "The place of each Rex session this file attached, by session ID.")

(defvar tmux-control--stand-ins (make-hash-table :test #'equal)
  "The buffer standing in for each place whose attach has yet to answer.")

(defun tmux-control-buffer-host ()
  "Return the SSH host of the current buffer's connection, nil when local."
  (nth 0 tmux-control--place))

(defun tmux-control-buffer-socket-name ()
  "Return the socket name of the current buffer's connection."
  (nth 1 tmux-control--place))

(defun tmux-control-buffer-session ()
  "Return the session label of the current buffer's connection."
  (nth 2 tmux-control--place))

(defun tmux-control-active-pane ()
  "Return the ID of the Rex block the current buffer shows."
  (and tmux-control--place (rexel-block-id)))

(defun tmux-control-window-id ()
  "Return the ID of the current buffer's Rex session.
The helper records a task's session as its window: a task has one."
  (and tmux-control--place (rexel-session-id)))

(defun tmux-control--blocks (place)
  "The block buffers of the session at PLACE, attached or left behind."
  (seq-filter (lambda (buffer)
                (and (rexel-block-p buffer)
                     (equal (buffer-local-value 'tmux-control--place buffer) place)))
              (buffer-list)))

(defun tmux-control--attached-p (buffer)
  "Non-nil if block BUFFER's session is attached over a connection.
NEEDS: `rexel--conn'.  `rexel-block-live-p' is nil both for a block
whose connection ended and for one whose first screen is on its way."
  (buffer-local-value 'rexel--conn buffer))

(defun tmux-control--block-made ()
  "Note the place of a new block buffer and tell Roost of it.
On `rexel-block-mode-hook', which also runs when a stream is taken up
again."
  (when-let* ((rexel-block-mode)
              (place (gethash (rexel-session-id) tmux-control--places)))
    (unless tmux-control--place
      (setq tmux-control--place place)
      (add-hook 'kill-buffer-hook #'tmux-control--block-gone nil t)
      (run-hook-with-args 'tmux-control-window-buffer-functions (current-buffer))
      (tmux-control--show-beside (current-buffer)))))

(defun tmux-control--shown-of (place &optional except)
  "A window showing a block of PLACE other than the buffer EXCEPT, or nil."
  (seq-some (lambda (buffer)
              (and (not (eq buffer except)) (get-buffer-window buffer t)))
            (tmux-control--blocks place)))

(defun tmux-control--show-beside (buffer)
  "Show BUFFER, a block made in a session a window shows, beside that window.
As tmux-control tiles the panes of a tmux window: a task's shell is a
second block of its session."
  (when-let* ((place (buffer-local-value 'tmux-control--place buffer))
              ((not (get-buffer-window buffer t)))
              (window (tmux-control--shown-of place buffer)))
    (ignore-errors
      (let ((new (split-window window nil t)))
        (set-window-buffer new buffer)
        ;; As tmux makes a new pane the active one: the helper's reply,
        ;; which has Roost select it, can come after the block does, and
        ;; what you type meanwhile is for the shell you asked for.
        (when (and (eq window (selected-window)) (not (active-minibuffer-window)))
          (select-window new))))))

(defun tmux-control--block-gone ()
  "Give the window of a block that closed back to the block beside it."
  (when (and tmux-control--place
             (tmux-control--shown-of tmux-control--place (current-buffer)))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (ignore-errors (delete-window window)))))

(add-hook 'rexel-block-mode-hook #'tmux-control--block-made)


;;; Connecting

(defun tmux-control--endpoint (socket)
  "The Unix socket path of SOCKET, \"rex:unix:///PATH\" or \"rex:/PATH\"."
  (unless (string-prefix-p "rex:" socket)
    (user-error "Socket %s is not a Rex server's: name it rex:ADDRESS" socket))
  (let ((address (substring socket 4)))
    (cond ((string-prefix-p "unix://" address)
           (url-unhex-string (substring address 7)))
          ((file-name-absolute-p address) address)
          (t (user-error "This trial reaches a Rex server only at a Unix socket, not %s"
                         address)))))

(defun tmux-control--stand-in-for (place &optional shown)
  "Return a buffer to stand in for the block of the session at PLACE.
SHOWN if it is one for PLACE already, else a new one."
  (if (and (buffer-live-p shown)
           (eq (buffer-local-value 'major-mode shown) 'tmux-control-connecting-mode)
           (equal (buffer-local-value 'tmux-control--place shown) place))
      shown
    (let ((buffer (generate-new-buffer (format "*tmux-control: %s*" (nth 2 place)))))
      (with-current-buffer buffer
        (tmux-control-connecting-mode)
        (setq tmux-control--place place)
        (let ((inhibit-read-only t))
          (insert (format "Connecting to %s…\n" (nth 2 place)))))
      (run-hook-with-args 'tmux-control-window-buffer-functions buffer)
      buffer)))

(defun tmux-control--show (buffer window)
  "Show BUFFER in WINDOW."
  (when (and (window-live-p window) (buffer-live-p buffer))
    (with-selected-window window
      (switch-to-buffer buffer t))))

(defun tmux-control--main-block (place)
  "The block buffer a window is to show for PLACE: its agent's, made first."
  (car (sort (seq-filter #'tmux-control--attached-p (tmux-control--blocks place))
             (lambda (a b)
               (string< (or (rexel-block-id a) "") (or (rexel-block-id b) ""))))))

(defun tmux-control--arrived (place)
  "Put the block of PLACE wherever its stand-in shows, and drop the stand-in."
  (let ((stand-in (gethash place tmux-control--stand-ins))
        (block (tmux-control--main-block place)))
    (remhash place tmux-control--stand-ins)
    (when (buffer-live-p stand-in)
      (when block
        (dolist (window (get-buffer-window-list stand-in nil t))
          (tmux-control--show block window))
        (with-current-buffer block
          (tmux-control-tile)))
      (unless (get-buffer-window stand-in t)
        (kill-buffer stand-in)))))

(defun tmux-control--failed (place why)
  "Say WHY the session at PLACE could not be attached, in its stand-in."
  (let ((stand-in (gethash place tmux-control--stand-ins)))
    (remhash place tmux-control--stand-ins)
    (when (buffer-live-p stand-in)
      (with-current-buffer stand-in
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert why "\n"))))
    (message "%s" why)))

;; A Rex server on a host Roost reaches over SSH: its Unix socket is
;; forwarded to one on this machine, by an ssh of its own that lasts as
;; long as Emacs, and rexel dials that.  Rex can also serve its API on a
;; tailnet, which `rexel-hosts' reaches with no forward; not tried here.

(defvar tmux-control-forward-directory (format "/tmp/roost-rex-%d/" (user-uid))
  "Where the forwarded sockets of remote Rex servers are kept.
Short, since a Unix socket's path is.")

(defvar tmux-control--forwards (make-hash-table :test #'equal)
  "The ssh forwarding each remote server's socket, by (HOST . PATH).")

(defun tmux-control--forward (host path callback)
  "Call CALLBACK with a socket on this machine that reaches PATH on HOST.
With nil and why not, when ssh could not forward it."
  (let* ((key (cons host path))
         (local (expand-file-name (concat (substring (md5 (format "%S" key)) 0 12) ".sock")
                                  tmux-control-forward-directory))
         (process (gethash key tmux-control--forwards)))
    (if (and (process-live-p process) (file-exists-p local))
        (funcall callback local nil)
      (unless (process-live-p process)
        (with-file-modes #o700
          (make-directory tmux-control-forward-directory t))
        (when (file-exists-p local)
          (delete-file local))
        (setq process
              (make-process
               :name (format "roost-rex-forward %s" host)
               :buffer (generate-new-buffer (format " *roost-rex-forward %s*" host))
               :command (list "ssh" "-N" "-T" "-o" "BatchMode=yes"
                              "-o" "ExitOnForwardFailure=yes"
                              "-L" (concat local ":" path) host)
               :connection-type 'pipe :noquery t))
        (puthash key process tmux-control--forwards))
      (let ((tries 100) timer)
        (setq timer
              (run-at-time
               0.1 0.1
               (lambda ()
                 (cond ((file-exists-p local)
                        (cancel-timer timer)
                        (funcall callback local nil))
                       ((or (not (process-live-p process))
                            (< (setq tries (1- tries)) 0))
                        (cancel-timer timer)
                        (let ((said (and (buffer-live-p (process-buffer process))
                                         (with-current-buffer (process-buffer process)
                                           (string-trim (buffer-string))))))
                          (when (process-live-p process)
                            (delete-process process))
                          (funcall callback nil
                                   (format "No way to the Rex server on %s: %s" host
                                           (if (string-empty-p (or said ""))
                                               "ssh did not forward its socket" said)))))))))))))

(defun tmux-control--attach (place)
  "Attach the Rex session at PLACE.  Its blocks' buffers come later.
NEEDS: `rexel--connect', `rexel--find-session', `rexel--request' and
`rexel--apply-view'.  A public function that attaches a session by
label on a server at a given address, without showing or asking, and
says when it has or why it could not, would replace all four.
`rexel--attach' says nothing to its caller of a session that is gone."
  (ghostel-ensure-module)
  (let ((host (nth 0 place))
        (path (tmux-control--endpoint (nth 1 place))))
    (if (not host)
        (tmux-control--attach-at place (list nil path))
      ;; The server's files are the host's, as TRAMP names them.
      (setf (alist-get host rexel-tramp-hosts nil nil #'equal)
            (format "/ssh:%s:" host))
      (tmux-control--forward
       host path
       (lambda (local why)
         (if local
             (tmux-control--attach-at place (list host local))
           (tmux-control--failed place why)))))))

(defun tmux-control--attach-at (place server)
  "Attach the Rex session at PLACE on SERVER, a (LABEL SOCKET) of rexel's."
  (let ((label (nth 2 place)))
    (rexel--connect
     server
     (lambda (conn)
       (rexel--find-session
        conn label
        (lambda (sid)
          (if (not sid)
              (tmux-control--failed place (format "No Rex session %s" label))
            (puthash sid place tmux-control--places)
            (rexel--request
             conn "session.attach" `((session_id . ,sid))
             (lambda (result err)
               (if err
                   (tmux-control--failed
                    place (format "Rex session %s: %s" label (alist-get 'message err)))
                 (rexel--apply-view conn sid (alist-get 'view result))
                 ;; A buffer the last connection left has its place already.
                 (dolist (buffer (rexel--session-buffers sid))
                   (with-current-buffer buffer
                     (unless tmux-control--place
                       (setq tmux-control--place place))))
                 (tmux-control--arrived place)))))))))))

(defun tmux-control--make-room (place window)
  "Before WINDOW shows the session at PLACE, close what is beside it.
The windows showing the other blocks of a session WINDOW shows a block
of now: tmux-control's one terminal swaps a session's panes as a whole."
  (when-let* ((old (buffer-local-value 'tmux-control--place (window-buffer window)))
              ((not (equal old place))))
    (dolist (buffer (tmux-control--blocks old))
      (dolist (other (get-buffer-window-list buffer nil (window-frame window)))
        (unless (eq other window)
          (ignore-errors (delete-window other)))))))

(defun tmux-control-connect-or-switch (host socket-name session)
  "Show Rex SESSION of the server SOCKET-NAME in the selected window.
An attached session is shown at once.  Otherwise the window shows a
buffer that stands in for its block until the server has answered."
  (let* ((socket (or socket-name tmux-control-default-socket-name))
         (place (list (and host (not (string-empty-p host)) host) socket session))
         (window (selected-window))
         (shown (window-buffer window))
         (block (tmux-control--main-block place))
         (waiting (gethash place tmux-control--stand-ins)))
    (tmux-control--make-room place window)
    (cond
     (block
      (unless (equal (buffer-local-value 'tmux-control--place (window-buffer window)) place)
        (tmux-control--show block window))
      ;; Its other blocks, as a task's shell, beside it again.
      (with-current-buffer block
        (tmux-control-tile)))
     ((buffer-live-p waiting)
      (tmux-control--show waiting window))
     (t
      (let ((stand-in (tmux-control--stand-in-for place shown)))
        (puthash place stand-in tmux-control--stand-ins)
        (tmux-control--show stand-in window)
        (condition-case err
            (tmux-control--attach place)
          ((error quit)
           (remhash place tmux-control--stand-ins)
           (when (and (window-live-p window) (eq (window-buffer window) stand-in)
                      (buffer-live-p shown) (not (eq shown stand-in)))
             (set-window-buffer window shown))
           (kill-buffer stand-in)
           (signal (car err) (cdr err)))))))))

(defun tmux-control-connect (&optional host socket-name session)
  "Show Rex SESSION of SOCKET-NAME.  Not one of Roost's calls."
  (tmux-control-connect-or-switch host socket-name session))

(defun tmux-control-disconnect ()
  "Detach the current buffer's session.  rexel kills its block buffers."
  (interactive)
  (when (and tmux-control--place (rexel-block-p))
    (rexel-detach)))

(defun tmux-control-reconnect ()
  "Attach the session the current buffer showed again, in the selected window."
  (interactive)
  (let ((place (or tmux-control--place
                   (user-error "No Rex session recorded in this buffer"))))
    (apply #'tmux-control-connect-or-switch place)))


;;; Commands to tmux

;; Roost sends two: `select-window', to the task's window of a session
;; that may hold others, and `display-message' for the window's ID, to
;; know that tmux has made a split.  A Rex session of ours holds one task.

(defun tmux-control-send-command (_command)
  "Nothing: no tmux is here to take a command."
  nil)

(defun tmux-control-query (_command callback)
  "Call CALLBACK soon with the current buffer's session ID, as a reply's lines."
  (when tmux-control--place
    (let ((reply (list (or (rexel-session-id) ""))))
      (run-at-time 0 nil callback reply))))

(defun tmux-control-select-pane (&optional pane)
  "Show and select the block PANE, an ID, of the current session.
One the server made a moment ago has no buffer until rexel hears of
it: looked for again, for two seconds."
  (when (and tmux-control--place (stringp pane))
    (let ((window (selected-window))
          (place tmux-control--place)
          (tries 20)
          timer)
      (cl-labels ((look ()
                    (if-let* ((buffer (rexel-block-buffer pane)))
                        (let ((shown (get-buffer-window buffer))
                              ;; Found late, you may be elsewhere by now, as
                              ;; in a question: it is shown, not selected.
                              (still (and (eq (selected-window) window)
                                          (window-live-p window)
                                          (equal (buffer-local-value 'tmux-control--place
                                                                     (window-buffer window))
                                                 place))))
                          (when timer (cancel-timer timer))
                          (when (or (not timer) still)
                            (unless shown (tmux-control--show buffer window))
                            (when (window-live-p (or shown window))
                              (select-window (or shown window)))))
                      (when (and timer (<= (cl-decf tries) 0))
                        (cancel-timer timer)))))
        (unless (rexel-block-buffer pane)
          (setq timer (run-at-time 0.1 0.1 #'look)))
        (look)))))


;;; A window's panes side by side

(defun tmux-control-tiled-p ()
  "Non-nil when another block of the current buffer's session shows too."
  (and tmux-control--place
       (tmux-control--shown-of tmux-control--place (current-buffer))
       t))

(defun tmux-control-tile ()
  "Show every block of the current buffer's session side by side."
  (interactive)
  (when tmux-control--place
    (mapc #'tmux-control--show-beside
          (seq-filter #'tmux-control--attached-p
                      (tmux-control--blocks tmux-control--place)))))

(provide 'tmux-control)
;;; tmux-control.el ends here
