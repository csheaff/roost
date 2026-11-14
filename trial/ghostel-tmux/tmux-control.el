;;; tmux-control.el --- Trial: what Roost calls of tmux-control, on ghostel-tmux  -*- lexical-binding: t; -*-

;; Version: 99.0
;; Package-Requires: ((emacs "30.1") (ghostel "0.65.0") (ghostel-tmux "0.3.0"))
;; Written against ghostel-tmux main at 70c9507 (2026-11-14).

;;; Commentary:

;; A trial, not for release.  Roost reaches its terminals through about
;; twenty functions, two hooks and one mode of tmux-control.  This file
;; gives them the same names on top of ghostel-tmux, so that Roost runs
;; unchanged with this directory on the load path in place of
;; tmux-control's:
;;
;;   emacs -L trial/ghostel-tmux -L <ghostel>/lisp -L <ghostel-tmux> ...
;;
;; Each definition says what it needed of ghostel-tmux that is not public
;; there, marked NEEDS.  Those notes are the point of the trial: they are
;; what a move of Roost to ghostel-tmux would ask of it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ghostel)
(require 'ghostel-tmux)

(defgroup tmux-control nil
  "Trial stand-in for tmux-control on ghostel-tmux."
  :group 'terminals)

(defconst tmux-control-version "99.0"
  "A version above any Roost asks for.")

(defcustom tmux-control-default-socket-name "main"
  "Default tmux socket name."
  :type 'string)

(defvar tmux-control-ssh-options nil
  "Unused here: ghostel-tmux reaches a remote host through TRAMP.")

(defvar tmux-control-remote-tmux-socket-setup
  "fs=$(stat -f -c %T \"$HOME\" 2>/dev/null); case \"$fs\" in nfs|nfs4|lustre|gpfs|cifs|smb*|afs) d=\"/tmp/tmux-$(id -u)-sock\";; *) d=\"$HOME/.tmux-sock\";; esac; mkdir -p \"$d\" && chmod 700 \"$d\" && export TMUX_TMPDIR=\"$d\""
  "Shell snippet run before tmux on a remote host, as tmux-control has it.
Roost's helper runs it too, so both find the same tmux server.")

(defvar tmux-control-session-activity nil
  "Unused here: ghostel-tmux names no other session's activity.")

(defvar tmux-control-switch-session-functions nil
  "Never run here: ghostel-tmux has no command that switches session.")

(defvar tmux-control-window-buffer-functions nil
  "Functions called with each pane buffer ghostel-tmux makes.
NEEDS a hook in ghostel-tmux for a new pane buffer.")

;; Roost asks `derived-mode-p' of `tmux-control-mode', and then for the
;; buffer's session, which a plain Ghostel terminal has none of.
(derived-mode-add-parents 'ghostel-mode '(tmux-control-mode))

(define-derived-mode tmux-control-connecting-mode special-mode "Connecting"
  "For the buffer a window shows until its tmux session's pane arrives.")
(derived-mode-add-parents 'tmux-control-connecting-mode '(tmux-control-mode))


;;; Which session a buffer belongs to

(defvar-local tmux-control--place nil
  "The (HOST SOCKET SESSION) of this controller or pane buffer.
NEEDS a way to ask a pane buffer for its session, socket and host.
ghostel-tmux keeps the server in the private `ghostel-tmux--server', as
tmux's arguments, and the host only as the remote part of
`default-directory'.")

(defvar-local tmux-control--stand-in nil
  "In a controller, the buffer that stands in for its pane until it arrives.
`ghostel-tmux-attach' returns before any pane is there.  Roost needs a
buffer of the session in the window at once, as tmux-control's terminal
was: it sends the session commands from the window's buffer right after
it connects, and it drops an open whose window shows another session by
the time its host replies.")

(defvar-local tmux-control--stands-in-for nil
  "In a buffer standing in for a pane, the controller it waits for.")

(defun tmux-control--controller ()
  "The live controller of the current buffer, or nil.
A pane's, the one a stand-in waits for, or the buffer itself."
  (let ((controller (or ghostel-tmux--controller-buffer
                        (and ghostel-tmux--controller-process (current-buffer))
                        tmux-control--stands-in-for)))
    (and (buffer-live-p controller) controller)))

(defun tmux-control--buffer-place ()
  "The place of the current buffer.  A pane buffer keeps its controller's."
  (or tmux-control--place
      (when-let* ((controller (tmux-control--controller))
                  (place (buffer-local-value 'tmux-control--place controller)))
        (setq tmux-control--place place))))

(defun tmux-control-buffer-host ()
  "Return the SSH host of the current buffer's connection, nil when local."
  (nth 0 (tmux-control--buffer-place)))

(defun tmux-control-buffer-socket-name ()
  "Return the tmux socket name of the current buffer's connection."
  (nth 1 (tmux-control--buffer-place)))

(defun tmux-control-buffer-session ()
  "Return the tmux session name of the current buffer's connection."
  (nth 2 (tmux-control--buffer-place)))

(defun tmux-control-active-pane ()
  "Return the id of the tmux pane the current buffer sends input to.
A pane buffer of ghostel-tmux is one pane for good."
  (and ghostel-tmux--pane-id
       (tmux-control--buffer-place)
       (format "%%%d" ghostel-tmux--pane-id)))

(defun tmux-control-window-id ()
  "Return the id of the tmux window holding the current buffer's pane."
  (and ghostel-tmux--window-id
       (tmux-control--buffer-place)
       (format "@%d" ghostel-tmux--window-id)))


;;; Connecting

(defvar tmux-control--socket-paths (make-hash-table :test #'equal)
  "The path of each remote socket, by (HOST . SOCKET).")

(defun tmux-control--socket (host socket)
  "SOCKET on HOST as `ghostel-tmux-attach' takes it: a name, or a path.
On a remote host, the path `tmux-control-remote-tmux-socket-setup' puts
it at, asked of the host once: Roost's helper runs that setup before
tmux, and ghostel-tmux has no command to run first."
  (if (not host)
      socket
    (or (gethash (cons host socket) tmux-control--socket-paths)
        (let ((default-directory (format "/ssh:%s:" host)))
          (with-temp-buffer
            (and (eql 0 (process-file
                         "sh" nil t nil "-c"
                         (concat tmux-control-remote-tmux-socket-setup
                                 " && printf %s \"$TMUX_TMPDIR/tmux-$(id -u)/$1\"")
                         "sh" socket))
                 (puthash (cons host socket) (string-trim (buffer-string))
                          tmux-control--socket-paths))))
        socket)))

(defun tmux-control--find-controller (place)
  "The live controller attached to PLACE, or nil."
  (seq-find (lambda (buffer)
              (and (equal (buffer-local-value 'tmux-control--place buffer) place)
                   (process-live-p
                    (buffer-local-value 'ghostel-tmux--controller-process buffer))))
            (buffer-list)))

(defun tmux-control--snapshots (place)
  "The pane buffers left of a connection to PLACE that ended."
  (seq-filter (lambda (buffer)
                (and (equal (buffer-local-value 'tmux-control--place buffer) place)
                     (buffer-local-value 'ghostel-tmux-pane-mode buffer)
                     (not (buffer-live-p
                           (buffer-local-value 'ghostel-tmux--controller-buffer buffer)))))
              (buffer-list)))

(defun tmux-control--stand-in-for (place &optional shown)
  "Return a buffer to stand in for the pane of the session at PLACE.
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

(defun tmux-control--show-stand-in (stand-in controller window)
  "Show STAND-IN for CONTROLLER's pane in WINDOW.
A split of another session that WINDOW is part of collapses into it
first, as it does when ghostel-tmux shows a pane of another session
there: left split, it would be tiled again over the stand-in.
NEEDS a public way to show a buffer of one's own in a pane's window:
`ghostel-tmux--tile-leaf', `--tile-windows' and `--tile-collapse'."
  (when controller
    (with-current-buffer controller
      (setq tmux-control--stand-in stand-in))
    (with-current-buffer stand-in
      (setq tmux-control--stands-in-for controller)))
  (unless (eq (window-buffer window) stand-in)
    (when-let* ((tile (ghostel-tmux--tile-leaf window)))
      (ghostel-tmux--tile-collapse
       (ghostel-tmux--tile-windows (nth 0 tile) (nth 1 tile)) window))
    (when (window-live-p window)
      (with-selected-window window
        (switch-to-buffer stand-in t)))))

(defun tmux-control--sweep-stand-ins ()
  "Kill the stand-ins no window shows whose pane has come or never will."
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'tmux-control-connecting-mode)
               (not (get-buffer-window buffer t)))
      (let ((controller (buffer-local-value 'tmux-control--stands-in-for buffer)))
        (unless (and (buffer-live-p controller)
                     (process-live-p (buffer-local-value 'ghostel-tmux--controller-process
                                                         controller))
                     (not (with-current-buffer controller (ghostel-tmux--attach-pane))))
          (kill-buffer buffer))))))

(defun tmux-control-connect-or-switch (host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME in the selected window.
A live connection to the session is reused.  The panes a connection
that ended left behind come alive again, as ghostel-tmux does it.
Returns before the pane is there: until tmux reports it the window shows
a buffer that stands in for it.
NEEDS, of ghostel-tmux: an attach that finds a session already attached
rather than attaching twice."
  (let* ((host (and host (not (string-empty-p host)) host))
         (socket (or socket-name tmux-control-default-socket-name))
         (place (list host socket session))
         (window (selected-window))
         (shown (window-buffer window))
         (controller (tmux-control--find-controller place)))
    (tmux-control--sweep-stand-ins)
    (cond
     ((and controller (with-current-buffer controller (ghostel-tmux--attach-pane)))
      (with-current-buffer controller
        (ghostel-tmux--display-pane-in-window (ghostel-tmux--attach-pane) window)))
     (controller
      ;; Its first pane is yet to come: this window waits for it too.
      (tmux-control--show-stand-in
       (or (let ((stand-in (buffer-local-value 'tmux-control--stand-in controller)))
             (and (buffer-live-p stand-in) stand-in))
           (tmux-control--stand-in-for place shown))
       controller window))
     ((memq shown (tmux-control--snapshots place))
      ;; A pane the session's last connection left: ghostel-tmux makes it
      ;; live again where it is.
      (let ((default-directory (if host (format "/ssh:%s:" host) (expand-file-name "~/"))))
        (with-current-buffer (ghostel-tmux-attach session (tmux-control--socket host socket))
          (setq tmux-control--place place))))
     (t
      (let ((default-directory (if host (format "/ssh:%s:" host) (expand-file-name "~/")))
            (path (tmux-control--socket host socket))
            (stand-in (tmux-control--stand-in-for place shown)))
        (tmux-control--show-stand-in stand-in nil window)
        (condition-case err
            (let ((controller (ghostel-tmux-attach session path)))
              (with-current-buffer controller
                (setq tmux-control--place place))
              (tmux-control--show-stand-in stand-in controller window))
          ((error quit)
           (when (and (window-live-p window) (eq (window-buffer window) stand-in)
                      (buffer-live-p shown) (not (eq shown stand-in)))
             (set-window-buffer window shown))
           (kill-buffer stand-in)
           (signal (car err) (cdr err)))))))))

(defun tmux-control--arrived (controller)
  "Put CONTROLLER's active pane wherever its stand-in shows.
Once no minibuffer is open: see the advice below."
  (when (buffer-live-p controller)
    (let ((stand-in (buffer-local-value 'tmux-control--stand-in controller)))
      (when (buffer-live-p stand-in)
        (if (> (minibuffer-depth) 0)
            (letrec ((later (lambda ()
                              (remove-hook 'minibuffer-exit-hook later)
                              ;; Once the command that asked is done, and
                              ;; Emacs has put the windows back.
                              (run-at-time 0 nil #'tmux-control--arrived controller))))
              (add-hook 'minibuffer-exit-hook later))
          (with-current-buffer controller
            (when-let* ((pane (ghostel-tmux--attach-pane)))
              (dolist (window (get-buffer-window-list stand-in nil t))
                (ghostel-tmux--display-pane-in-window pane window))
              (setq tmux-control--stand-in nil)
              (kill-buffer stand-in))))))))

(define-advice ghostel-tmux--receive-window-rows
    (:around (fn output &optional seed) tmux-control-arrived)
  "Have a session of Roost's arrive where its stand-in shows, and quietly.
With SEED, tmux lists the session's windows for the first time.
NEEDS a hook for that, and an attach that claims no window: the pane is
shown here, in place of its stand-in, so ghostel-tmux's own claim,
`ghostel-tmux--auto-host-window', is withdrawn first.
The pane waits for the minibuffer to close before it takes a window.
Emacs puts the windows back as they were when a question in the
minibuffer is answered or quit (`read-minibuffer-restore-windows'),
which would take the pane out of its window again.  ghostel-tmux waits
by itself since 33c746f; `tmux-control--arrived' has to as well, as it
is this file that places the pane.
NEEDS an attach that says nothing.  ghostel-tmux says \"Attached to
SESSION\" here, which is after Roost has said in the echo area why it
brought you to a task.  `inhibit-message' would not do: a message it
hides still clears the echo area.
By the time the rows are read every pane tmux still has is live again:
the pane buffers an earlier connection left that are not, tmux no longer
has."
  (let ((ours (and seed tmux-control--place)))
    (when (and ours (buffer-live-p tmux-control--stand-in))
      (setq ghostel-tmux--auto-host-window nil))
    (prog1 (cl-letf* ((say (symbol-function 'message))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (unless (and ours (stringp format-string)
                                      (string-prefix-p "Ghostel-tmux: Attached to"
                                                       format-string))
                           (apply say format-string args)))))
             (funcall fn output seed))
      (when ours
        (tmux-control--arrived (current-buffer))
        (mapc #'kill-buffer (tmux-control--snapshots ours))))))

(defun tmux-control-connect (&optional host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME, creating it if it is not there.
Not one of Roost's calls: its tests connect a terminal of your own."
  (let ((socket (or socket-name tmux-control-default-socket-name)))
    (unless (or host
                (eql 0 (call-process ghostel-tmux-program nil nil nil
                                     "-L" socket "has-session" "-t" (concat "=" session))))
      (call-process ghostel-tmux-program nil nil nil "-L" socket "new-session" "-d" "-s" session))
    (tmux-control-connect-or-switch host socket session)))

(defun tmux-control-disconnect ()
  "Disconnect the current buffer's client, keeping its panes as they were."
  (interactive)
  (when-let* ((controller (tmux-control--controller)))
    (with-current-buffer controller
      (ghostel-tmux-detach t))))

(defun tmux-control-reconnect ()
  "Connect the session the current buffer showed again, in the selected window.
Attaching makes its sealed pane buffers live again."
  (interactive)
  (let ((place (or (tmux-control--buffer-place)
                   (user-error "No tmux session recorded in this buffer"))))
    (apply #'tmux-control-connect-or-switch place)))


;;; Commands to tmux

(defvar-local tmux-control--early nil
  "In a controller: what was asked of tmux before it answered, newest first.
Each is (COMMAND . CONT), as `ghostel-tmux--queue-command' takes them.")

(defun tmux-control--queue (controller command &optional cont)
  "Have CONTROLLER send tmux COMMAND and call CONT with its reply.
NEEDS a public way to send a command, one that waits until tmux is
there: `ghostel-tmux--queue-command' writes at once.  Since an attach
returns before tmux has started, what Roost sends right after it can
reach the host first.  Over TRAMP the shell that starts tmux reads ahead
and takes the command with it, as TRAMP has the terminal out of line
mode for a process on a pipe.  ghostel-tmux then waits for a reply that
never comes and sends nothing more: the session gets no panes.  So a
command waits here until tmux names its session."
  (with-current-buffer controller
    (if ghostel-tmux--session-id
        (ghostel-tmux--queue-command command cont)
      (push (cons command cont) tmux-control--early))))

(define-advice ghostel-tmux--on-session-changed
    (:after (&rest _) tmux-control-early)
  "Send what was asked of the session before tmux answered."
  (pcase-dolist (`(,command . ,cont)
                 (nreverse (prog1 tmux-control--early
                             (setq tmux-control--early nil))))
    (ghostel-tmux--queue-command command cont)))

(defun tmux-control-send-command (command)
  "Send tmux COMMAND over the current buffer's connection."
  (when-let* ((controller (tmux-control--controller)))
    (tmux-control--queue controller command)))

(defun tmux-control-query (command callback)
  "Send tmux COMMAND and call CALLBACK with its reply's lines, or nil.
NEEDS the same as `tmux-control-send-command', with the reply."
  (when-let* ((controller (tmux-control--controller)))
    (tmux-control--queue
     controller command
     (lambda (output)
       (funcall callback (and output (split-string output "\n" t)))))))

(defun tmux-control-select-pane (&optional pane)
  "Show and select PANE, a pane id such as \"%3\", of the current session.
NEEDS a public way to show a pane by its id in a window:
`ghostel-tmux--panes' and `ghostel-tmux--select-pane-buffer'."
  (when-let* ((controller (tmux-control--controller))
              ((stringp pane))
              ((string-match "\\`%\\([0-9]+\\)\\'" pane)))
    (let* ((id (string-to-number (match-string 1 pane)))
           (panes (buffer-local-value 'ghostel-tmux--panes controller))
           (buffer (and panes (gethash id panes))))
      (if (not (buffer-live-p buffer))
          ;; Not told of the pane yet: tmux's report of the selection
          ;; shows it.
          (tmux-control--queue controller (format "select-pane -t %s" pane))
        (ghostel-tmux--select-pane-buffer buffer)))))


;;; A window's panes side by side

(defun tmux-control-tiled-p ()
  "Return non-nil when the current buffer's tmux window shows as a split.
ghostel-tmux splits a tmux window of several panes by itself, with
`ghostel-tmux-split-windows'.
NEEDS a public way to ask: `ghostel-tmux--tile-windows'."
  (when-let* ((controller (tmux-control--controller))
              (window ghostel-tmux--window-id))
    (and (ghostel-tmux--tile-windows controller window) t)))

(defun tmux-control-tile ()
  "Show every pane of the current tmux window, as tmux lays them out."
  (interactive)
  (when (tmux-control--controller)
    (ghostel-tmux-restore-split)))


;;; A new pane buffer

(define-advice ghostel-tmux--get-or-create-pane
    (:around (fn controller pane-id &rest args) tmux-control-window-buffer)
  "Run `tmux-control-window-buffer-functions' for a pane buffer just made."
  (let* ((panes (buffer-local-value 'ghostel-tmux--panes controller))
         (known (and panes (gethash pane-id panes)))
         (buffer (apply fn controller pane-id args)))
    (unless (buffer-live-p known)
      (with-current-buffer buffer
        (setq tmux-control--place (buffer-local-value 'tmux-control--place controller)))
      (run-hook-with-args 'tmux-control-window-buffer-functions buffer))
    buffer))

(provide 'tmux-control)
;;; tmux-control.el ends here
